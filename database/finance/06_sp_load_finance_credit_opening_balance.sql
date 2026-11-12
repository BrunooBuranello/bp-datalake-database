-- ============================================================
-- PROCEDURE: bp_datalake.sp_load_finance_credit_opening_balance
--
-- OBJETIVO:
-- Carga ÚNICA do saldo inicial do AR / Crédito: transforma a
-- coluna "Recebido" da aba BASE da planilha do Financeiro (já no
-- banco em bronze_finance_credit_base, integração finance_credit)
-- em lançamentos OPENING_BALANCE. ADR-002 do app finance.
--
-- QUANDO RODAR:
-- Na virada, depois da última carga da planilha e antes de o
-- Financeiro começar a lançar pelo app. Antes disso, a coluna
-- "Recebido" ainda está mudando na planilha.
--     CALL sp_load_finance_credit_opening_balance('<usuário>');
--
-- REGRAS:
--   - Chave da planilha: chassi + NF + data. A NF é completada
--     para 9 dígitos. Casa com a gold_finance_credit_receivable
--     (que tem a planta).
--   - Linhas repetidas da mesma chave na BASE mostram o MESMO
--     "Recebido" (a planilha soma a aba CARS por chassi + NF): usa
--     o MAIOR valor, nunca a soma, para não duplicar.
--   - Valor 0 ou vazio não gera lançamento.
--   - Chave que casa com mais de uma NF da receivable (mesmo
--     chassi + NF + data em plantas diferentes) é AMBÍGUA: fica
--     de fora e aparece na contagem.
--   - Linhas da BASE sem par na receivable ficam de fora (medido
--     em 11/11/2026: ~20 mil com recebido). Consulta no README.
--
-- SEGURANÇA:
--   - Recusa rodar de novo se já existir lançamento
--     LEGACY_SPREADSHEET (carga única).
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
    DECLARE v_ambiguous INT DEFAULT 0;
    DECLARE v_unmatched INT DEFAULT 0;

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


    /*
    01. Recebido por chave da planilha (chassi + NF 9 dígitos + data).
    "1234,50" e "1234.5" convivem na coluna TEXT: troca vírgula por ponto.
    */
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_sheet;
    CREATE TEMPORARY TABLE tmp_fcob_sheet AS
    SELECT
        -- A BASE é TEXT: CHAR com collation explícita permite a PRIMARY
        -- KEY da temporária e o JOIN com a receivable (0900_ai_ci).
        CAST(UPPER(TRIM(b.chassis)) AS CHAR(17)) COLLATE utf8mb4_0900_ai_ci AS chassis_serial_number,
        CAST(LPAD(TRIM(b.invoice_number), 9, '0') AS CHAR(9)) COLLATE utf8mb4_0900_ai_ci AS invoice_number,
        DATE(LEFT(TRIM(b.issuance_date), 10)) AS issuance_date,
        MAX(CAST(REPLACE(TRIM(b.amount_received), ',', '.') AS DECIMAL(15,2))) AS received_amount
    FROM bp_datalake.bronze_finance_credit_base AS b
    WHERE TRIM(b.chassis) REGEXP '^[A-Za-z0-9]{17}$'
      AND TRIM(b.invoice_number) REGEXP '^[0-9]{1,9}$'
      AND TRIM(b.issuance_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
      AND TRIM(b.amount_received) REGEXP '^-?[0-9]+([.,][0-9]+)?$'
    GROUP BY 1, 2, 3
    HAVING received_amount <> 0;

    ALTER TABLE tmp_fcob_sheet
        ADD PRIMARY KEY (chassis_serial_number, invoice_number, issuance_date);


    /*
    02. Casa com a receivable e conta as NFs por chave (ambiguidade).
    */
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_match;
    CREATE TEMPORARY TABLE tmp_fcob_match AS
    SELECT
        t.chassis_serial_number,
        t.invoice_number,
        t.issuance_date,
        t.received_amount,
        COUNT(r.id) AS match_count,
        MIN(r.plant_code) AS plant_code
    FROM tmp_fcob_sheet AS t
    LEFT JOIN bp_datalake.gold_finance_credit_receivable AS r
        ON  r.chassis_serial_number = t.chassis_serial_number
        AND r.invoice_number = t.invoice_number
        AND r.issuance_date = t.issuance_date
    GROUP BY
        t.chassis_serial_number, t.invoice_number, t.issuance_date, t.received_amount;

    SET v_unmatched = (SELECT COUNT(*) FROM tmp_fcob_match WHERE match_count = 0);
    SET v_ambiguous = (SELECT COUNT(*) FROM tmp_fcob_match WHERE match_count > 1);


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
        NULL, m.received_amount,
        'Saldo inicial: coluna Recebido da planilha CRÉDITO DEALER',
        'LEGACY_SPREADSHEET',
        1, TRIM(p_loaded_by), v_now
    FROM tmp_fcob_match AS m
    WHERE m.match_count = 1;

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
        'OPENING_BALANCE', r.received_amount, NULL, r.observation,
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

    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_sheet;
    DROP TEMPORARY TABLE IF EXISTS tmp_fcob_match;

    SELECT
        v_inserted AS opening_receipts_inserted,
        v_unmatched AS sheet_keys_without_invoice,
        v_ambiguous AS sheet_keys_ambiguous;

END$$

DELIMITER ;
