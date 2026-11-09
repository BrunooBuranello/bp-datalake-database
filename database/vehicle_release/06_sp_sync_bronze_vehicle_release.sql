-- ============================================================
-- PROCEDURE: bp_datalake.sp_sync_bronze_vehicle_release
-- CAMADA: Bronze (gerada a partir da Gold)
--
-- OBJETIVO:
-- Montar/atualizar a bronze_vehicle_release (status de liberação
-- de cada NF) e registrar a execução e as mudanças de status.
--
-- QUEM CHAMA:
-- - fim da sp_process_zsdbil17_pipeline (como a DEMO):
--     CALL sp_sync_bronze_vehicle_release('PIPELINE', 'pipeline', @run_id);
-- - botão "Executar validação" do app (trigger_source = BUTTON,
--   triggered_by = usuário logado).
--
-- ESCOPO (fase 1, 09/11/2026):
-- Grupo 1 = Revenda (division B1) e Test Drive (B2), NFs atuais
-- da Gold (record_source = ZSDBIL17_CURRENT) emitidas a partir de
-- c_start_issuance_date. Locadoras entram quando a lista de CNPJs
-- do app existir. Grupo 2 (VD B5, PCD B3, Táxi B4) e
-- Demo/Showroom/Asset/Seguradora ficam fora.
--
-- REGRAS (Grupo 1), avaliadas nesta ordem para o status:
--  0. Já liberado:
--     a) chave consta como RELEASED no histórico manual
--        (bronze_chassis_released_to_logistics); ou
--     b) pedido do CRM já passou da expedição
--        (order_status To Be Received / Completed).
--  2. Prazo de pagamento > 30 dias. Dias = dim_cond_pagamento
--     (desc_prazo_pgto_atribuicao_bp) ou, quando a dim traz "-",
--     o número de "dentro de N dias" do texto SAP. Sem dias ou
--     <= 30 -> REVIEW_PAYMENT_TERM (faturamento errado ou à vista).
--  1. Chave chassi + NF + data consta na bronze_finance_credit_base
--     -> senão WAITING_FINANCE.
--  3. CRM: chassi + NF + data acha exatamente 1 pedido e o
--     order_sub_status = 'To Be Shipped' -> senão WAITING_CRM.
--  Tudo ok -> READY_TO_RELEASE.
--  release_status_reason lista TODAS as regras que falharam.
--
-- CHAVE DO CRM (chassi + NF + data):
-- medido em 09/11/2026 para Revenda/Test Drive desde 01/10:
-- 20.747 NFs; só chassi = 21.012 linhas do CRM (pedidos
-- repetidos); chassi + NF + data = 20.709 NFs com exatamente
-- 1 pedido cada (99,8%). Consulta de referência no README.
--
-- SEGURANÇA DA OPERAÇÃO:
-- - GET_LOCK impede duas execuções simultâneas.
-- - BUTTON é recusado enquanto a pipeline Z17 estiver RUNNING
--   (evita ler a Gold no meio da atualização).
-- - Erro: ROLLBACK, run_status = ERROR, SEM RESIGNAL, para não
--   derrubar a pipeline Z17 (mesmo padrão do cancelamento manual).
-- - Idempotente: rodar de novo sem mudança nas fontes não gera
--   eventos novos no audit_history.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_sync_bronze_vehicle_release;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_sync_bronze_vehicle_release(
    IN  p_trigger_source VARCHAR(20),
    IN  p_triggered_by VARCHAR(150),
    OUT p_run_id BIGINT
)
BEGIN

    /*
    Corte da fase 1: NFs emitidas a partir desta data.
    O histórico manual (planilha antiga) cobre até 14/10/2026;
    NFs anteriores já liberadas aparecem como RELEASED.
    */
    DECLARE c_start_issuance_date DATE DEFAULT '2026-10-01';
    DECLARE c_lock_name VARCHAR(64) DEFAULT 'bp_datalake.vehicle_release_sync';

    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;
    DECLARE v_lock_acquired INT DEFAULT 0;

    DECLARE v_crm_last_load DATETIME DEFAULT NULL;
    DECLARE v_finance_last_load DATETIME DEFAULT NULL;
    DECLARE v_finance_rows INT DEFAULT 0;

    DECLARE v_gold_rows INT DEFAULT 0;
    DECLARE v_inserted INT DEFAULT 0;
    DECLARE v_changed INT DEFAULT 0;
    DECLARE v_removed INT DEFAULT 0;


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
            -- Falhou antes de registrar a execução: devolve o erro.
            RESIGNAL;
        END IF;

        UPDATE bp_datalake.bronze_vehicle_release_run_audit_history
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

    IF p_trigger_source NOT IN ('PIPELINE', 'BUTTON')
       OR NULLIF(TRIM(p_triggered_by), '') IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_sync_bronze_vehicle_release: trigger_source deve ser PIPELINE ou BUTTON e triggered_by é obrigatório';
    END IF;

    INSERT INTO bp_datalake.bronze_vehicle_release_run_audit_history (
        trigger_source,
        triggered_by,
        started_at,
        run_status,
        start_issuance_date
    )
    VALUES (
        p_trigger_source,
        TRIM(p_triggered_by),
        NOW(6),
        'RUNNING',
        c_start_issuance_date
    );

    SET p_run_id = LAST_INSERT_ID();


    /*
    ============================================================
    02. TRAVAS: execução simultânea e pipeline Z17 em andamento
    ============================================================
    */

    -- GET_LOCK devolve 1 (ok), 0 (ocupado) ou NULL (erro): NULL vira 0.
    SET v_lock_acquired = COALESCE(GET_LOCK(c_lock_name, 0), 0);

    IF v_lock_acquired <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Outra execução da Liberação está em andamento. Tente de novo em alguns minutos.';
    END IF;

    /*
    Só para o botão: dentro da pipeline, a própria pipeline está
    RUNNING. Janela de 3 horas para não travar por um log antigo
    que ficou RUNNING após queda do servidor.
    */
    IF p_trigger_source = 'BUTTON' AND EXISTS (
        SELECT 1
        FROM bp_datalake.etl_execution_log
        WHERE procedure_name = 'sp_process_zsdbil17_pipeline'
          AND execution_status = 'RUNNING'
          AND started_at >= NOW() - INTERVAL 3 HOUR
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A pipeline da Z17 está atualizando a Gold agora. Rode a validação depois que ela terminar.';
    END IF;


    /*
    ============================================================
    03. FRESCOR DAS FONTES
    crm_is_fresh = YES quando o CRM foi carregado hoje: a liberação
    de hoje precisa do CRM de hoje (pedido do Bruno, 09/11/2026).
    ============================================================
    */

    SELECT MAX(dt_carga)
    INTO v_crm_last_load
    FROM bp_datalake.dwd_sal_slm_base_order_details;

    SELECT
        COUNT(*),
        MAX(
            CASE
                WHEN TRIM(dt_carga) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                THEN CAST(LEFT(TRIM(dt_carga), 19) AS DATETIME)
            END
        )
    INTO v_finance_rows, v_finance_last_load
    FROM bp_datalake.bronze_finance_credit_base;


    /*
    ============================================================
    04. FONTES AUXILIARES (tabelas temporárias com índice)
    ============================================================
    */

    -- 04.1 CRM: um registro por chassi + NF + data, com a contagem
    -- de pedidos (>1 = ambíguo, vai para revisão).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_crm;
    CREATE TEMPORARY TABLE tmp_vr_crm (
        vin VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        invoice_date DATE NOT NULL,
        match_count INT NOT NULL,
        order_no VARCHAR(100) NULL,
        order_status VARCHAR(100) NULL,
        order_sub_status VARCHAR(100) NULL,
        PRIMARY KEY (vin, invoice_number, invoice_date)
    );

    INSERT INTO tmp_vr_crm
    SELECT
        UPPER(TRIM(c.vin_code)),
        LPAD(TRIM(c.sap_nf_e_no), 9, '0'),
        DATE(c.invoice_date),
        COUNT(*),
        MAX(c.order_no),
        MAX(c.order_status),
        MAX(c.order_sub_status)
    FROM bp_datalake.dwd_sal_slm_base_order_details AS c
    WHERE c.invoice_date >= c_start_issuance_date
      AND CHAR_LENGTH(TRIM(c.vin_code)) = 17
      AND TRIM(c.sap_nf_e_no) REGEXP '^[0-9]{1,9}$'
    GROUP BY
        UPPER(TRIM(c.vin_code)),
        LPAD(TRIM(c.sap_nf_e_no), 9, '0'),
        DATE(c.invoice_date);

    -- 04.2 BASE do financeiro normalizada (NF 9 dígitos, data DATE).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_finance;
    CREATE TEMPORARY TABLE tmp_vr_finance (
        chassis VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        issuance_date DATE NOT NULL,
        PRIMARY KEY (chassis, invoice_number, issuance_date)
    );

    INSERT IGNORE INTO tmp_vr_finance
    SELECT
        k.chassis,
        k.invoice_number,
        k.issuance_date
    FROM (
        SELECT
            UPPER(TRIM(f.chassis)) AS chassis,
            LPAD(TRIM(f.invoice_number), 9, '0') AS invoice_number,
            CASE
                WHEN TRIM(f.issuance_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                    THEN STR_TO_DATE(LEFT(TRIM(f.issuance_date), 10), '%Y-%m-%d')
                WHEN TRIM(f.issuance_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}'
                    THEN STR_TO_DATE(LEFT(TRIM(f.issuance_date), 10), '%d/%m/%Y')
            END AS issuance_date
        FROM bp_datalake.bronze_finance_credit_base AS f
        WHERE CHAR_LENGTH(TRIM(f.chassis)) = 17
          AND TRIM(f.invoice_number) REGEXP '^[0-9]{1,9}$'
    ) AS k
    WHERE k.issuance_date IS NOT NULL;

    -- 04.3 Histórico manual de liberação (planilha antiga).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_legacy_released;
    CREATE TEMPORARY TABLE tmp_vr_legacy_released (
        chassis VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        issuance_date DATE NOT NULL,
        PRIMARY KEY (chassis, invoice_number, issuance_date)
    );

    INSERT IGNORE INTO tmp_vr_legacy_released
    SELECT
        UPPER(TRIM(l.chassi)),
        LPAD(TRIM(l.nf), 9, '0'),
        l.issuance_date
    FROM bp_datalake.bronze_chassis_released_to_logistics AS l
    WHERE l.status = 'RELEASED'
      AND l.issuance_date >= c_start_issuance_date
      AND CHAR_LENGTH(TRIM(l.chassi)) = 17
      AND TRIM(l.nf) REGEXP '^[0-9]{1,9}$';


    /*
    ============================================================
    05. AVALIAÇÃO DAS REGRAS (foto desta execução)
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_vr_eval;
    CREATE TEMPORARY TABLE tmp_vr_eval AS
    SELECT
        g.chassis_serial_number,
        g.invoice_number,
        g.issuance_date,
        g.plant_code,
        g.proc_time,
        g.division,
        g.division_description,
        g.sold_to_party_code,
        g.sold_to_party_cnpj,
        g.sold_to_party_name,
        g.ship_to_party_code,
        g.ship_to_party_cnpj,
        g.ship_to_party_name,
        g.dealer_group,
        g.store_name_crm,
        g.material,
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
        ) AS payment_term_days,

        IF(f.chassis IS NOT NULL, 'YES', 'NO') AS finance_base_found,
        IF(l.chassis IS NOT NULL, 'YES', 'NO') AS legacy_released,

        COALESCE(c.match_count, 0) AS crm_match_count,
        c.order_no AS crm_order_no,
        c.order_status AS crm_order_status,
        c.order_sub_status AS crm_order_sub_status

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_cond_pagamento AS d
        ON d.cond_pgto_sap = g.payment_condition

    LEFT JOIN tmp_vr_finance AS f
        ON  f.chassis = g.chassis_serial_number
        AND f.invoice_number = g.invoice_number
        AND f.issuance_date = g.issuance_date

    LEFT JOIN tmp_vr_legacy_released AS l
        ON  l.chassis = g.chassis_serial_number
        AND l.invoice_number = g.invoice_number
        AND l.issuance_date = g.issuance_date

    LEFT JOIN tmp_vr_crm AS c
        ON  c.vin = g.chassis_serial_number
        AND c.invoice_number = g.invoice_number
        AND c.invoice_date = g.issuance_date

    WHERE g.record_source = 'ZSDBIL17_CURRENT'
      AND g.division IN ('B1', 'B2')
      AND g.issuance_date >= c_start_issuance_date
      AND g.plant_code IS NOT NULL;

    SET v_gold_rows = (SELECT COUNT(*) FROM tmp_vr_eval);

    -- Status e motivo calculados numa 2ª etapa (lê as colunas acima).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_source;
    CREATE TEMPORARY TABLE tmp_vr_source AS
    SELECT
        e.*,

        IF(e.payment_term_days > 30, 'YES', 'NO') AS payment_term_ok,

        CASE
            WHEN e.legacy_released = 'YES' THEN 'RELEASED'
            WHEN e.crm_match_count = 1
             AND e.crm_order_status IN ('To Be Received', 'Completed')
                THEN 'RELEASED'
            WHEN e.payment_term_days IS NULL OR e.payment_term_days <= 30
                THEN 'REVIEW_PAYMENT_TERM'
            WHEN e.finance_base_found = 'NO' THEN 'WAITING_FINANCE'
            WHEN e.crm_match_count <> 1
              OR e.crm_order_sub_status IS NULL
              OR e.crm_order_sub_status <> 'To Be Shipped'
                THEN 'WAITING_CRM'
            ELSE 'READY_TO_RELEASE'
        END AS release_status,

        CASE
            WHEN e.legacy_released = 'YES' THEN 'LEGACY_HISTORY'
            WHEN e.crm_match_count = 1
             AND e.crm_order_status IN ('To Be Received', 'Completed')
                THEN 'CRM_STATUS'
        END AS released_source,

        CASE
            WHEN e.legacy_released = 'YES'
                THEN 'Liberado no controle manual (planilha antiga)'
            WHEN e.crm_match_count = 1
             AND e.crm_order_status IN ('To Be Received', 'Completed')
                THEN CONCAT('Pedido já saiu no CRM: ', e.crm_order_status)
            ELSE NULLIF(
                CONCAT_WS('; ',
                    CASE
                        WHEN e.payment_term_days IS NULL
                            THEN CONCAT('Condição ', IFNULL(e.payment_condition, '(vazia)'), ' sem prazo em dias')
                        WHEN e.payment_term_days <= 30
                            THEN CONCAT('Prazo de ', e.payment_term_days, ' dias (precisa ser maior que 30)')
                    END,
                    IF(e.finance_base_found = 'NO',
                        'Chave chassi + NF + data não consta na BASE do financeiro', NULL),
                    CASE
                        WHEN e.crm_match_count = 0
                            THEN 'Pedido não encontrado no CRM (chassi + NF + data)'
                        WHEN e.crm_match_count > 1
                            THEN 'Mais de um pedido no CRM para a mesma NF'
                        WHEN IFNULL(e.crm_order_sub_status, '') <> 'To Be Shipped'
                            THEN CONCAT('CRM ainda não está em To Be Shipped (',
                                        IFNULL(e.crm_order_sub_status, 'sem sub-status'), ')')
                    END
                ),
                ''
            )
        END AS release_status_reason

    FROM tmp_vr_eval AS e;

    ALTER TABLE tmp_vr_source
        ADD PRIMARY KEY (chassis_serial_number, invoice_number, issuance_date, plant_code);


    /*
    ============================================================
    06. GRAVAÇÃO (transação única)
    ============================================================
    */

    START TRANSACTION;

    -- 06.1 Eventos: NF nova ou status diferente do atual.
    INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
        run_id, triggered_by,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        change_type, old_status, new_status, status_reason, changed_at
    )
    SELECT
        p_run_id,
        TRIM(p_triggered_by),
        s.chassis_serial_number,
        s.invoice_number,
        s.issuance_date,
        s.plant_code,
        IF(r.id IS NULL, 'INSERTED', 'STATUS_CHANGED'),
        r.release_status,
        s.release_status,
        s.release_status_reason,
        v_now
    FROM tmp_vr_source AS s
    LEFT JOIN bp_datalake.bronze_vehicle_release AS r
        ON  r.chassis_serial_number = s.chassis_serial_number
        AND r.invoice_number = s.invoice_number
        AND r.issuance_date = s.issuance_date
        AND r.plant_code = s.plant_code
    WHERE r.id IS NULL
       OR r.release_status <> s.release_status;

    SELECT
        COALESCE(SUM(change_type = 'INSERTED'), 0),
        COALESCE(SUM(change_type = 'STATUS_CHANGED'), 0)
    INTO v_inserted, v_changed
    FROM bp_datalake.bronze_vehicle_release_audit_history
    WHERE run_id = p_run_id;

    -- 06.2 Upsert da foto atual.
    -- status_since vem ANTES de release_status no UPDATE: o MySQL
    -- aplica as atribuições da esquerda para a direita.
    INSERT INTO bp_datalake.bronze_vehicle_release (
        chassis_serial_number, invoice_number, issuance_date, plant_code, proc_time,
        division, division_description, release_group, is_rental_company,
        sold_to_party_code, sold_to_party_cnpj, sold_to_party_name,
        ship_to_party_code, ship_to_party_cnpj, ship_to_party_name,
        dealer_group, store_name_crm,
        material, model_simplified,
        total_amount, payment_condition, payment_term_days, payment_term_ok,
        finance_base_found, finance_base_loaded_at,
        crm_match_count, crm_order_no, crm_order_status, crm_order_sub_status, crm_loaded_at,
        release_status, release_status_reason, released_source, in_gold,
        status_since, first_seen_at, last_run_id
    )
    SELECT
        s.chassis_serial_number, s.invoice_number, s.issuance_date, s.plant_code, s.proc_time,
        s.division, s.division_description, 'GROUP_1', 'NO',
        s.sold_to_party_code, s.sold_to_party_cnpj, s.sold_to_party_name,
        s.ship_to_party_code, s.ship_to_party_cnpj, s.ship_to_party_name,
        s.dealer_group, s.store_name_crm,
        s.material, s.model_simplified,
        s.total_amount, s.payment_condition, s.payment_term_days, s.payment_term_ok,
        s.finance_base_found, v_finance_last_load,
        LEAST(s.crm_match_count, 127), s.crm_order_no, s.crm_order_status, s.crm_order_sub_status, v_crm_last_load,
        s.release_status, s.release_status_reason, s.released_source, 'YES',
        v_now, v_now, p_run_id
    FROM tmp_vr_source AS s
    ON DUPLICATE KEY UPDATE
        status_since = IF(
            bronze_vehicle_release.release_status <> s.release_status,
            v_now,
            bronze_vehicle_release.status_since
        ),
        proc_time = s.proc_time,
        division = s.division,
        division_description = s.division_description,
        sold_to_party_code = s.sold_to_party_code,
        sold_to_party_cnpj = s.sold_to_party_cnpj,
        sold_to_party_name = s.sold_to_party_name,
        ship_to_party_code = s.ship_to_party_code,
        ship_to_party_cnpj = s.ship_to_party_cnpj,
        ship_to_party_name = s.ship_to_party_name,
        dealer_group = s.dealer_group,
        store_name_crm = s.store_name_crm,
        material = s.material,
        model_simplified = s.model_simplified,
        total_amount = s.total_amount,
        payment_condition = s.payment_condition,
        payment_term_days = s.payment_term_days,
        payment_term_ok = s.payment_term_ok,
        finance_base_found = s.finance_base_found,
        finance_base_loaded_at = v_finance_last_load,
        crm_match_count = LEAST(s.crm_match_count, 127),
        crm_order_no = s.crm_order_no,
        crm_order_status = s.crm_order_status,
        crm_order_sub_status = s.crm_order_sub_status,
        crm_loaded_at = v_crm_last_load,
        release_status = s.release_status,
        release_status_reason = s.release_status_reason,
        released_source = s.released_source,
        in_gold = 'YES',
        last_run_id = p_run_id;

    -- 06.3 NFs que saíram da Gold (cancelada/refaturada): evento.
    INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
        run_id, triggered_by,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        change_type, old_status, new_status, status_reason, changed_at
    )
    SELECT
        p_run_id,
        TRIM(p_triggered_by),
        r.chassis_serial_number,
        r.invoice_number,
        r.issuance_date,
        r.plant_code,
        'REMOVED_FROM_GOLD',
        r.release_status,
        'NOT_IN_GOLD',
        'NF saiu da Gold (cancelada ou refaturada)',
        v_now
    FROM bp_datalake.bronze_vehicle_release AS r
    WHERE r.in_gold = 'YES'
      AND NOT EXISTS (
          SELECT 1
          FROM tmp_vr_source AS s
          WHERE s.chassis_serial_number = r.chassis_serial_number
            AND s.invoice_number = r.invoice_number
            AND s.issuance_date = r.issuance_date
            AND s.plant_code = r.plant_code
      );

    SET v_removed = ROW_COUNT();

    -- 06.4 Marca essas NFs na foto atual.
    UPDATE bp_datalake.bronze_vehicle_release AS r
    INNER JOIN bp_datalake.bronze_vehicle_release_audit_history AS a
        ON  a.run_id = p_run_id
        AND a.change_type = 'REMOVED_FROM_GOLD'
        AND a.chassis_serial_number = r.chassis_serial_number
        AND a.invoice_number = r.invoice_number
        AND a.issuance_date = r.issuance_date
        AND a.plant_code = r.plant_code
    SET
        r.in_gold = 'NO',
        r.status_since = v_now,
        r.release_status = 'NOT_IN_GOLD',
        r.release_status_reason = 'NF saiu da Gold (cancelada ou refaturada)',
        r.last_run_id = p_run_id;

    -- 06.5 Fecha a execução com a foto dos totais.
    UPDATE bp_datalake.bronze_vehicle_release_run_audit_history AS run
    CROSS JOIN (
        SELECT
            SUM(release_status = 'READY_TO_RELEASE') AS qty_ready,
            SUM(release_status = 'WAITING_FINANCE') AS qty_finance,
            SUM(release_status = 'WAITING_CRM') AS qty_crm,
            SUM(release_status = 'REVIEW_PAYMENT_TERM') AS qty_term,
            SUM(release_status = 'RELEASED') AS qty_released,
            SUM(release_status = 'NOT_IN_GOLD') AS qty_not_in_gold
        FROM bp_datalake.bronze_vehicle_release
    ) AS totals
    SET
        run.finished_at = NOW(6),
        run.run_status = 'SUCCESS',
        run.gold_rows_read = v_gold_rows,
        run.nfs_inserted = v_inserted,
        run.status_changes = v_changed,
        run.nfs_removed_from_gold = v_removed,
        run.qty_ready_to_release = COALESCE(totals.qty_ready, 0),
        run.qty_waiting_finance = COALESCE(totals.qty_finance, 0),
        run.qty_waiting_crm = COALESCE(totals.qty_crm, 0),
        run.qty_review_payment_term = COALESCE(totals.qty_term, 0),
        run.qty_released = COALESCE(totals.qty_released, 0),
        run.qty_not_in_gold = COALESCE(totals.qty_not_in_gold, 0),
        run.crm_last_load_at = v_crm_last_load,
        run.crm_is_fresh = IF(DATE(v_crm_last_load) = CURDATE(), 'YES', 'NO'),
        run.finance_base_last_load_at = v_finance_last_load,
        run.finance_base_rows = v_finance_rows
    WHERE run.run_id = p_run_id;

    COMMIT;

    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

    DROP TEMPORARY TABLE IF EXISTS tmp_vr_source;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_eval;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_crm;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_finance;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_legacy_released;

END$$

DELIMITER ;
