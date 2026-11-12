-- ============================================================
-- PROCEDURE: bp_datalake.sp_load_finance_credit_opening_balance
--
-- OBJETIVO:
-- Carga ÚNICA do saldo inicial do AR / Crédito a partir da aba CARS
-- da planilha CRÉDITO DEALER (foto em bronze_finance_credit_cars).
-- ADR-002, ADR-007 e ADR-008 do app finance.
--
-- QUANDO RODAR (virada):
--   1. o Financeiro para de lançar na planilha;
--   2. python manage.py load_finance_credit_cars --user <usuário>;
--   3. CALL sp_load_finance_credit_opening_balance('<usuário>');
--   4. daqui em diante, recebimento só pelo app (com data).
--
-- REGRAS (ADR-008, 12/11/2026):
--   - Na planilha, "Recebido" da BASE =
--     SE(chassi + NF está na CARS; valor da NF; 0). O Financeiro
--     confirmou: só existe pagamento de 100%. Por isso a fonte é a
--     CARS: chave chassi + NF presente = NF paga inteira.
--   - Valor do lançamento = total_amount da NF no AR / Crédito (Z17).
--     A CARS não tem valor.
--   - Chave da CARS = chassi + NF (sem data e sem planta). Casa com o
--     AR / Crédito só quando existe EXATAMENTE 1 NF com esse chassi +
--     NF (em 12/11/2026 todas as 416.854 são únicas). Mais de uma =
--     AMBÍGUA, fica de fora (nunca escolhemos uma NF).
--   - Data do recebimento = PAYMENT DATE da CARS quando a chave tem
--     uma data só. Sem data, ou com datas diferentes nas repetições,
--     fica sem data (as datas ficam na observação). Data futura é
--     descartada.
--   - NUNCA DUPLICAR (regra): a CARS repete chaves; agrupamos por
--     chave e cada NF recebe no máximo um saldo inicial.
--   - NF com valor zero ou sem valor não gera lançamento.
--
-- SEGURANÇA:
--   - Recusa rodar de novo se já existir lançamento
--     LEGACY_SPREADSHEET (carga única) e se a foto da CARS estiver
--     vazia ou tiver mais de uma carga misturada.
--   - Tudo numa transação: lançamentos, auditoria e received_amount.
--   - Devolve as contagens num SELECT final.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_load_finance_credit_opening_balance;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_load_finance_credit_opening_balance(
    IN p_loaded_by VARCHAR(150)
)
BEGIN

    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_inserted INT DEFAULT 0;
    DECLARE v_with_date INT DEFAULT 0;
    DECLARE v_multiple_dates INT DEFAULT 0;
    DECLARE v_unmatched INT DEFAULT 0;
    DECLARE v_ambiguous INT DEFAULT 0;
    DECLARE v_without_amount INT DEFAULT 0;
    DECLARE v_invalid_rows INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NULLIF(TRIM(p_loaded_by), '') IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_load_finance_credit_opening_balance: informe quem está carregando.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM bp_datalake.bronze_finance_credit_receipt
        WHERE entry_source = 'LEGACY_SPREADSHEET'
        LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Saldo inicial já carregado: esta carga só roda uma vez.';
    END IF;

    IF (SELECT COUNT(DISTINCT load_id) FROM bp_datalake.bronze_finance_credit_cars) <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Foto da CARS vazia ou misturada: rode load_finance_credit_cars antes.';
    END IF;

    SET v_invalid_rows = (
        SELECT COUNT(*) FROM bp_datalake.bronze_finance_credit_cars WHERE key_valid = 'NO'
    );


    /*
    01. Uma linha por chave chassi + NF da CARS (a aba repete chaves).
    Datas futuras não contam como data de pagamento.
    */
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_cars;
    CREATE TEMPORARY TABLE tmp_fcob_cars AS
    SELECT
        c.chassis_serial_number,
        c.invoice_number,
        COUNT(DISTINCT IF(c.payment_date <= CURDATE(), c.payment_date, NULL)) AS date_count,
        MIN(IF(c.payment_date <= CURDATE(), c.payment_date, NULL)) AS payment_date,
        GROUP_CONCAT(
            DISTINCT DATE_FORMAT(IF(c.payment_date <= CURDATE(), c.payment_date, NULL), '%d/%m/%Y')
            SEPARATOR ', '
        ) AS payment_dates_text
    FROM bp_datalake.bronze_finance_credit_cars AS c
    WHERE c.key_valid = 'YES'
    GROUP BY c.chassis_serial_number, c.invoice_number;

    ALTER TABLE tmp_fcob_cars
        ADD PRIMARY KEY (chassis_serial_number, invoice_number);


    /*
    02. Casa com o AR / Crédito por chassi + NF e conta as NFs por
    chave (ambiguidade).
    */
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_match;
    CREATE TEMPORARY TABLE tmp_fcob_match AS
    SELECT
        t.chassis_serial_number,
        t.invoice_number,
        t.date_count,
        t.payment_date,
        t.payment_dates_text,
        COUNT(r.id) AS match_count,
        MIN(r.issuance_date) AS issuance_date,
        MIN(r.plant_code) AS plant_code,
        MIN(r.total_amount) AS total_amount
    FROM tmp_fcob_cars AS t
    LEFT JOIN bp_datalake.gold_finance_credit_receivable AS r
        ON  r.chassis_serial_number = t.chassis_serial_number
        AND r.invoice_number = t.invoice_number
    GROUP BY
        t.chassis_serial_number, t.invoice_number,
        t.date_count, t.payment_date, t.payment_dates_text;

    SET v_unmatched = (SELECT COUNT(*) FROM tmp_fcob_match WHERE match_count = 0);
    SET v_ambiguous = (SELECT COUNT(*) FROM tmp_fcob_match WHERE match_count > 1);
    SET v_without_amount = (
        SELECT COUNT(*) FROM tmp_fcob_match
        WHERE match_count = 1 AND COALESCE(total_amount, 0) <= 0
    );
    SET v_multiple_dates = (
        SELECT COUNT(*) FROM tmp_fcob_match
        WHERE match_count = 1 AND total_amount > 0 AND date_count > 1
    );


    /*
    03. Grava lançamentos, auditoria e o received_amount (uma transação).
    */
    START TRANSACTION;

    INSERT INTO bp_datalake.bronze_finance_credit_receipt (
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        input_key_type, input_key_text,
        received_date, received_amount, observation, entry_source,
        active, created_by, created_at
    )
    SELECT
        m.chassis_serial_number, m.invoice_number, m.issuance_date, m.plant_code,
        'OPENING_BALANCE',
        CONCAT(m.chassis_serial_number, '-', TRIM(LEADING '0' FROM m.invoice_number)),
        IF(m.date_count = 1, m.payment_date, NULL),
        m.total_amount,
        CASE
            WHEN m.date_count > 1 THEN CONCAT(
                'Saldo inicial: chave na aba CARS da planilha CRÉDITO DEALER (NF paga 100%); ',
                'datas diferentes na CARS: ', LEFT(m.payment_dates_text, 150)
            )
            ELSE 'Saldo inicial: chave na aba CARS da planilha CRÉDITO DEALER (NF paga 100%)'
        END,
        'LEGACY_SPREADSHEET',
        1, TRIM(p_loaded_by), v_now
    FROM tmp_fcob_match AS m
    WHERE m.match_count = 1
      AND m.total_amount > 0;

    SET v_inserted = ROW_COUNT();

    INSERT INTO bp_datalake.bronze_finance_credit_receipt_audit_history (
        receipt_id,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        action_type, received_amount, received_date, reason,
        changed_by, changed_at
    )
    SELECT
        r.id,
        r.chassis_serial_number, r.invoice_number, r.issuance_date, r.plant_code,
        'OPENING_BALANCE', r.received_amount, r.received_date, r.observation,
        r.created_by, r.created_at
    FROM bp_datalake.bronze_finance_credit_receipt AS r
    WHERE r.entry_source = 'LEGACY_SPREADSHEET';

    UPDATE bp_datalake.gold_finance_credit_receivable AS g
    INNER JOIN bp_datalake.bronze_finance_credit_receipt AS r
        ON  r.chassis_serial_number = g.chassis_serial_number
        AND r.invoice_number = g.invoice_number
        AND r.issuance_date = g.issuance_date
        AND r.plant_code = g.plant_code
        AND r.entry_source = 'LEGACY_SPREADSHEET'
    SET
        g.received_amount = g.received_amount + r.received_amount,
        g.last_receipt_at = v_now;

    COMMIT;

    SET v_with_date = (
        SELECT COUNT(*) FROM bp_datalake.bronze_finance_credit_receipt
        WHERE entry_source = 'LEGACY_SPREADSHEET' AND received_date IS NOT NULL
    );

    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_cars;
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_match;

    SELECT
        v_inserted AS opening_receipts_inserted,
        v_with_date AS with_payment_date,
        v_multiple_dates AS without_date_multiple_dates,
        v_unmatched AS cars_keys_without_invoice,
        v_ambiguous AS cars_keys_ambiguous,
        v_without_amount AS invoices_without_amount,
        v_invalid_rows AS cars_rows_invalid_key;

END$$

DELIMITER ;
