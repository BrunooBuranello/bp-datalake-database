-- ============================================================
-- PROCEDURE: bp_datalake.sp_sync_gold_finance_credit_receivable
--
-- OBJETIVO:
-- Gera/atualiza gold_finance_credit_receivable (AR / Crédito) a
-- partir da Gold Z17. ADR-001 do app finance.
--
-- QUEM CHAMA:
-- - fim da sp_process_zsdbil17_pipeline (passo 18.2):
--     CALL sp_sync_gold_finance_credit_receivable('PIPELINE', 'pipeline', @run_id);
-- - carga inicial no deploy / suporte:
--     CALL sp_sync_gold_finance_credit_receivable('MANUAL', '<usuário>', @run_id);
--
-- ESCOPO (todo o histórico da Gold, 11/11/2026):
--   B1 -> RESALE, B2 -> TEST_DRIVE, B3 -> PCD, B4 -> TAXI,
--   B5 -> DIRECT_SALE.
--   Legado 2024/2025 com outros códigos de division (ZZB4, ZZB7,
--   ZBRY, ZPJ1...): pela descrição RESALE / TEST DRIVE /
--   DIRECT SALE. COTA-CHECK, INSURANCE COMPANY, ASSET e DEMO ficam
--   fora. Medido em 11/11/2026: ~206 mil NFs atuais + ~211 mil do
--   legado (a BASE da planilha tinha ~420 mil linhas).
--
-- REGRAS:
--   - Cliente: RESALE e TEST_DRIVE usam o sold-to; os demais o
--     ship-to (pedido do Bruno, 11/11/2026).
--   - Vencimento = emissão + dias da condição de pagamento. Dias =
--     dim_cond_pagamento.desc_prazo_pgto_atribuicao_bp (numérico)
--     ou o "dentro de N dias" do texto SAP; "pagamento imediato" =
--     0. Sem dias -> due_date NULL (a NF continua na base).
--     Esta tabela tem a própria regra (não compartilha view com a
--     Liberação): a Liberação vai passar a ler desta tabela.
--   - received_amount NUNCA é alterado aqui (é a soma dos
--     lançamentos, mantida pelo app).
--   - NF que saiu da Gold vira in_gold = 'NO' (não é apagada).
--
-- SEGURANÇA DA OPERAÇÃO:
--   - GET_LOCK impede duas execuções simultâneas.
--   - Erro: ROLLBACK, run_status = ERROR, SEM RESIGNAL, para não
--     derrubar a pipeline Z17 (padrão da Liberação de Veículos).
--   - Idempotente.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_sync_gold_finance_credit_receivable;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_sync_gold_finance_credit_receivable(
    IN  p_trigger_source VARCHAR(20),
    IN  p_triggered_by VARCHAR(150),
    OUT p_run_id BIGINT
)
BEGIN

    DECLARE c_lock_name VARCHAR(64) DEFAULT 'bp_datalake.finance_credit_receivable_sync';

    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;
    DECLARE v_lock_acquired INT DEFAULT 0;

    DECLARE v_gold_rows INT DEFAULT 0;
    DECLARE v_inserted INT DEFAULT 0;
    DECLARE v_removed INT DEFAULT 0;
    DECLARE v_without_due_date INT DEFAULT 0;


    /*
    ============================================================
    TRATAMENTO DE ERRO
    Sem RESIGNAL depois que a execução foi registrada: o erro fica
    na run_audit_history e a pipeline Z17 continua.
    ============================================================
    */
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        IF v_lock_acquired = 1 THEN
            DO RELEASE_LOCK(c_lock_name);
        END IF;

        IF p_run_id IS NULL THEN
            RESIGNAL;
        END IF;

        UPDATE bp_datalake.gold_finance_credit_receivable_run_audit_history
        SET
            run_status = 'ERROR',
            finished_at = NOW(6),
            error_code = v_error_code,
            error_message = v_error_message
        WHERE run_id = p_run_id;
    END;


    /*
    ============================================================
    01. REGISTRA A EXECUÇÃO (fora da transação)
    ============================================================
    */

    SET p_run_id = NULL;

    IF p_trigger_source NOT IN ('PIPELINE', 'MANUAL')
       OR NULLIF(TRIM(p_triggered_by), '') IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_sync_gold_finance_credit_receivable: trigger_source deve ser PIPELINE ou MANUAL e triggered_by é obrigatório';
    END IF;

    INSERT INTO bp_datalake.gold_finance_credit_receivable_run_audit_history (
        trigger_source, triggered_by, started_at, run_status
    )
    VALUES (
        p_trigger_source, TRIM(p_triggered_by), NOW(6), 'RUNNING'
    );

    SET p_run_id = LAST_INSERT_ID();


    /*
    ============================================================
    02. TRAVA: uma execução por vez
    ============================================================
    */

    SET v_lock_acquired = COALESCE(GET_LOCK(c_lock_name, 0), 0);

    IF v_lock_acquired <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Outra atualização do AR / Crédito está em andamento. Tente de novo em alguns minutos.';
    END IF;


    /*
    ============================================================
    03. FONTE: NFs da Gold dentro do escopo, já classificadas
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_fcr_scope;
    CREATE TEMPORARY TABLE tmp_fcr_scope AS
    SELECT
        g.chassis_serial_number,
        g.invoice_number,
        g.issuance_date,
        TRIM(g.plant_code) AS plant_code,
        g.record_source,
        g.division,
        g.division_description,

        -- Tipo de venda: código B1..B5; no legado, pela descrição.
        CASE
            WHEN g.division = 'B1' THEN 'RESALE'
            WHEN g.division = 'B2' THEN 'TEST_DRIVE'
            WHEN g.division = 'B3' THEN 'PCD'
            WHEN g.division = 'B4' THEN 'TAXI'
            WHEN g.division = 'B5' THEN 'DIRECT_SALE'
            WHEN g.record_source = 'LEGACY_2024_2025'
                 AND UPPER(TRIM(g.division_description)) = 'RESALE' THEN 'RESALE'
            WHEN g.record_source = 'LEGACY_2024_2025'
                 AND UPPER(TRIM(g.division_description)) = 'TEST DRIVE' THEN 'TEST_DRIVE'
            WHEN g.record_source = 'LEGACY_2024_2025'
                 AND UPPER(TRIM(g.division_description)) = 'DIRECT SALE' THEN 'DIRECT_SALE'
        END AS sales_type,

        g.sold_to_party_code,
        g.sold_to_party_cnpj,
        g.sold_to_party_name,
        g.ship_to_party_code,
        g.ship_to_party_cnpj,
        g.ship_to_party_name,
        g.dealer_group,
        g.model_simplified,
        g.total_amount,
        g.payment_condition,

        -- Dias do prazo: dim numérica ou "dentro de N dias" do SAP.
        CAST(
            CASE
                WHEN TRIM(d.desc_prazo_pgto_atribuicao_bp) REGEXP '^[0-9]+$'
                    THEN TRIM(d.desc_prazo_pgto_atribuicao_bp)
                WHEN d.explicacao_propria_sap REGEXP 'dentro de [0-9]+ dias'
                    THEN REGEXP_SUBSTR(
                        REGEXP_SUBSTR(d.explicacao_propria_sap, 'dentro de [0-9]+ dias'),
                        '[0-9]+'
                    )
                WHEN d.explicacao_propria_sap LIKE 'pagamento imediato%'
                    THEN '0'
            END
            AS SIGNED
        ) AS payment_term_days

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_cond_pagamento AS d
        ON d.cond_pgto_sap = g.payment_condition

    WHERE g.plant_code IS NOT NULL
      AND TRIM(g.plant_code) <> ''
      AND (
            g.division IN ('B1', 'B2', 'B3', 'B4', 'B5')
            OR (
                g.record_source = 'LEGACY_2024_2025'
                AND UPPER(TRIM(g.division_description)) IN ('RESALE', 'TEST DRIVE', 'DIRECT SALE')
            )
      );

    /*
    Monta o cliente pelo papel (sold-to x ship-to), o vencimento e a
    chave antiga numa segunda etapa, para a regra ficar num lugar só.
    */
    DROP TEMPORARY TABLE IF EXISTS tmp_fcr_source;
    CREATE TEMPORARY TABLE tmp_fcr_source AS
    SELECT
        s.chassis_serial_number,
        s.invoice_number,
        s.issuance_date,
        s.plant_code,
        CONCAT(
            s.chassis_serial_number, '-',
            -- NF "000000000" (improvável) vira "0", não vazio.
            COALESCE(NULLIF(TRIM(LEADING '0' FROM s.invoice_number), ''), '0')
        ) AS legacy_key,
        s.record_source,
        s.division,
        s.division_description,
        s.sales_type,

        IF(s.sales_type IN ('RESALE', 'TEST_DRIVE'), 'SOLD_TO', 'SHIP_TO') AS customer_party_role,
        IF(s.sales_type IN ('RESALE', 'TEST_DRIVE'), s.sold_to_party_code, s.ship_to_party_code) AS customer_code,
        IF(s.sales_type IN ('RESALE', 'TEST_DRIVE'), s.sold_to_party_cnpj, s.ship_to_party_cnpj) AS customer_cnpj,
        LEFT(
            IF(s.sales_type IN ('RESALE', 'TEST_DRIVE'), s.sold_to_party_cnpj, s.ship_to_party_cnpj),
            8
        ) AS customer_cnpj_root,
        IF(s.sales_type IN ('RESALE', 'TEST_DRIVE'), s.sold_to_party_name, s.ship_to_party_name) AS customer_name,
        s.dealer_group,
        s.model_simplified,
        s.total_amount,
        s.payment_condition,
        s.payment_term_days,
        IF(
            s.payment_term_days IS NULL,
            NULL,
            DATE_ADD(s.issuance_date, INTERVAL s.payment_term_days DAY)
        ) AS due_date
    FROM tmp_fcr_scope AS s;

    ALTER TABLE tmp_fcr_source
        ADD PRIMARY KEY (chassis_serial_number, invoice_number, issuance_date, plant_code);

    SET v_gold_rows = (SELECT COUNT(*) FROM tmp_fcr_source);
    SET v_without_due_date = (SELECT COUNT(*) FROM tmp_fcr_source WHERE due_date IS NULL);

    -- Contagens antes de gravar (o upsert não diz quem entrou).
    SET v_inserted = (
        SELECT COUNT(*)
        FROM tmp_fcr_source AS s
        LEFT JOIN bp_datalake.gold_finance_credit_receivable AS r
            ON  r.chassis_serial_number = s.chassis_serial_number
            AND r.invoice_number = s.invoice_number
            AND r.issuance_date = s.issuance_date
            AND r.plant_code = s.plant_code
        WHERE r.id IS NULL
    );


    /*
    ============================================================
    04. GRAVAÇÃO (transação única)
    ============================================================
    */

    START TRANSACTION;

    -- 04.1 Upsert. received_amount/last_receipt_at ficam de fora do
    -- UPDATE: pertencem aos lançamentos do app.
    INSERT INTO bp_datalake.gold_finance_credit_receivable (
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        legacy_key, record_source,
        division, division_description, sales_type,
        customer_party_role, customer_code, customer_cnpj, customer_cnpj_root,
        customer_name, dealer_group, model_simplified,
        total_amount, payment_condition, payment_term_days, due_date,
        in_gold, first_seen_at, last_run_id
    )
    SELECT
        s.chassis_serial_number, s.invoice_number, s.issuance_date, s.plant_code,
        s.legacy_key, s.record_source,
        s.division, s.division_description, s.sales_type,
        s.customer_party_role, s.customer_code, s.customer_cnpj, s.customer_cnpj_root,
        s.customer_name, s.dealer_group, s.model_simplified,
        s.total_amount, s.payment_condition, s.payment_term_days, s.due_date,
        'YES', v_now, p_run_id
    FROM tmp_fcr_source AS s
    ON DUPLICATE KEY UPDATE
        legacy_key = VALUES(legacy_key),
        record_source = VALUES(record_source),
        division = VALUES(division),
        division_description = VALUES(division_description),
        sales_type = VALUES(sales_type),
        customer_party_role = VALUES(customer_party_role),
        customer_code = VALUES(customer_code),
        customer_cnpj = VALUES(customer_cnpj),
        customer_cnpj_root = VALUES(customer_cnpj_root),
        customer_name = VALUES(customer_name),
        dealer_group = VALUES(dealer_group),
        model_simplified = VALUES(model_simplified),
        total_amount = VALUES(total_amount),
        payment_condition = VALUES(payment_condition),
        payment_term_days = VALUES(payment_term_days),
        due_date = VALUES(due_date),
        -- last_run_id fica de fora de propósito: com ele, todas as
        -- ~417 mil linhas seriam regravadas a cada pipeline. Sem ele,
        -- o MySQL só grava a linha cujo conteúdo mudou.
        in_gold = 'YES';

    -- 04.2 NFs que saíram da Gold: marca, não apaga (podem ter recebido).
    UPDATE bp_datalake.gold_finance_credit_receivable AS r
    LEFT JOIN tmp_fcr_source AS s
        ON  s.chassis_serial_number = r.chassis_serial_number
        AND s.invoice_number = r.invoice_number
        AND s.issuance_date = r.issuance_date
        AND s.plant_code = r.plant_code
    SET
        r.in_gold = 'NO',
        r.last_run_id = p_run_id
    WHERE s.chassis_serial_number IS NULL
      AND r.in_gold = 'YES';

    SET v_removed = ROW_COUNT();

    -- 04.3 Fecha a execução.
    UPDATE bp_datalake.gold_finance_credit_receivable_run_audit_history
    SET
        finished_at = NOW(6),
        run_status = 'SUCCESS',
        gold_rows_read = v_gold_rows,
        nfs_inserted = v_inserted,
        nfs_removed_from_gold = v_removed,
        nfs_without_due_date = v_without_due_date,
        total_rows_after = (SELECT COUNT(*) FROM bp_datalake.gold_finance_credit_receivable)
    WHERE run_id = p_run_id;

    COMMIT;

    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

    DROP TEMPORARY TABLE IF EXISTS tmp_fcr_scope;
    DROP TEMPORARY TABLE IF EXISTS tmp_fcr_source;

END$$

DELIMITER ;
