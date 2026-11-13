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
-- ESCOPO (Grupo 1):
-- - Revenda (division B1) e Test Drive (B2);
-- - Locadora: Venda Direta (B5) cujo sold-to CNPJ está ativo na
--   dim_customer_classification como RENTAL_COMPANY (lista do
--   Financeiro, 12/11/2026: VD de Big Business com crédito próprio
--   é liberada como Revenda).
-- NFs atuais da Gold (record_source = ZSDBIL17_CURRENT) emitidas a
-- partir de c_start_issuance_date. Grupo 2 (VD comum, PCD B3,
-- Táxi B4) e Demo/Showroom/Asset/Seguradora ficam fora.
--
-- PAPEL DO APP (12/11/2026): a liberação de verdade acontece no CRM
-- (To Be Shipped -> Pending Factory Release). O app:
-- - orienta quem ainda não foi liberado (READY / WAITING_*);
-- - controla a liberação feita no CRM (control_alert);
-- - registra a liberação de NF sem pedido no CRM (casos offline,
--   tabela bronze_vehicle_release_manual_release);
-- - avisa quando o pedido muda no CRM depois de pronto/liberado
--   (crm_change_alert; bloqueia com CRM_CHANGED se ainda não saiu).
--
-- REGRAS, avaliadas nesta ordem para o status:
--  0. Já liberado -> RELEASED:
--     a) chave RELEASED no histórico manual antigo
--        (bronze_chassis_released_to_logistics) -> LEGACY_HISTORY;
--     b) liberação registrada no app (manual_release ativa) -> APP;
--     c) CRM com 1 pedido já liberado: sub-status Pending Factory
--        Release (BP liberou, aguarda a fábrica) ou order_status
--        To Be Received / Completed -> CRM_STATUS.
--        Sequência do CRM: To Be Dispatched (Allocated -> SAP
--        Processing -> To Be Shipped -> Pending Factory Release)
--        -> To Be Received (Left Factory) -> Completed (Arrived).
--  1. Prazo de pagamento > 30 dias. Dias = dim_cond_pagamento
--     (desc_prazo_pgto_atribuicao_bp) ou, quando a dim traz "-",
--     o número de "dentro de N dias" do texto SAP. Sem dias ou
--     <= 30 -> REVIEW_PAYMENT_TERM. Para locadora vale só se
--     c_rental_requires_payment_term = 1 (aguardando o supervisor).
--  2. Chave chassi + NF + data consta na bronze_finance_credit_base
--     -> senão WAITING_FINANCE. Linhas com a coluna L "Check
--     cancelado" preenchida (texto diferente de "-") são ignoradas:
--     marcam a própria NF como cancelada (Financeiro, 11/11/2026).
--  3. Pedido alterado no CRM depois da foto congelada -> CRM_CHANGED
--     (só quando todo o resto passou; bloqueia a liberação).
--  4. CRM: chassi + NF + data acha exatamente 1 pedido e o
--     order_sub_status = 'To Be Shipped' -> senão WAITING_CRM.
--  Tudo ok -> READY_TO_RELEASE.
--  release_status_reason lista TODAS as regras que falharam.
--
-- FOTO DO CRM (crm_snapshot_*): congelada na 1ª execução em que a
-- NF está READY_TO_RELEASE ou RELEASED com 1 pedido no CRM. Depois,
-- cada execução compara o CRM atual com a foto: pedido, modelo,
-- versão (config), cores, status que voltou e status de exceção
-- (cancelamento, devolução, erro). Diferença -> crm_change_alert.
-- A foto só muda por sp_accept_vehicle_release_crm_change (pessoa
-- confere e aceita no app).
--
-- CONTROLE DA LIBERAÇÃO NO CRM (control_alert): NF liberada pelo
-- CRM sem a chave na BASE do Financeiro ou com prazo que não passa.
--
-- CHAVE DO CRM (chassi + NF + data):
-- medido em 09/11/2026 para Revenda/Test Drive desde 01/10:
-- 20.747 NFs; só chassi = 21.012 linhas do CRM (pedidos
-- repetidos); chassi + NF + data = 20.709 NFs com exatamente
-- 1 pedido cada (99,8%). Consulta de referência no README.
--
-- SEGURANÇA DA OPERAÇÃO:
-- - GET_LOCK impede duas execuções simultâneas (o mesmo lock é
--   usado pelas procedures de liberação manual e de aceite).
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
    /*
    Locadora segue a regra de prazo > 30 dias da Revenda? 1 = sim
    (padrão: "semelhante aos casos de Revenda", e-mail do Financeiro
    de 12/11/2026); 0 = não. Aguardando confirmação do supervisor.
    */
    DECLARE c_rental_requires_payment_term TINYINT DEFAULT 1;

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
    -- de pedidos (>1 = ambíguo, vai para revisão). Modelo, versão e
    -- cores entram para a comparação com a foto congelada.
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_crm;
    CREATE TEMPORARY TABLE tmp_vr_crm (
        vin VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        invoice_date DATE NOT NULL,
        match_count INT NOT NULL,
        order_no VARCHAR(100) NULL,
        order_status VARCHAR(100) NULL,
        order_sub_status VARCHAR(100) NULL,
        vehicle_model_code VARCHAR(20) NULL,
        config_no VARCHAR(30) NULL,
        exterior_color_code VARCHAR(30) NULL,
        interior_color_code VARCHAR(30) NULL,
        PRIMARY KEY (vin, invoice_number, invoice_date)
    );

    INSERT INTO tmp_vr_crm
    SELECT
        UPPER(TRIM(c.vin_code)),
        LPAD(TRIM(c.sap_nf_e_no), 9, '0'),
        DATE(c.invoice_date),
        COUNT(*),
        LEFT(MAX(TRIM(c.order_no)), 100),
        LEFT(MAX(TRIM(c.order_status)), 100),
        LEFT(MAX(TRIM(c.order_sub_status)), 100),
        LEFT(MAX(NULLIF(TRIM(c.vehicle_model_code), '')), 20),
        LEFT(MAX(NULLIF(TRIM(c.config_no), '')), 30),
        LEFT(MAX(NULLIF(TRIM(c.exterior_color_code), '')), 30),
        LEFT(MAX(NULLIF(TRIM(c.interior_color_code), '')), 30)
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
          -- Coluna L preenchida = NF cancelada pelo Financeiro: não conta.
          AND COALESCE(NULLIF(TRIM(f.cancellation_check), ''), '-') = '-'
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

    -- 04.4 Locadoras: CNPJ completo ativo (lista do Financeiro).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_rental;
    CREATE TEMPORARY TABLE tmp_vr_rental (
        customer_cnpj CHAR(14) NOT NULL,
        PRIMARY KEY (customer_cnpj)
    );

    INSERT IGNORE INTO tmp_vr_rental
    SELECT customer_cnpj
    FROM bp_datalake.dim_customer_classification
    WHERE classification_type = 'RENTAL_COMPANY'
      AND is_active = 'YES';

    -- 04.5 Liberações registradas no app (NF sem pedido no CRM).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_manual;
    CREATE TEMPORARY TABLE tmp_vr_manual (
        chassis VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        issuance_date DATE NOT NULL,
        plant_code VARCHAR(10) NOT NULL,
        released_by VARCHAR(150) NOT NULL,
        release_reason VARCHAR(500) NOT NULL,
        PRIMARY KEY (chassis, invoice_number, issuance_date, plant_code)
    );

    INSERT INTO tmp_vr_manual
    SELECT
        m.chassis_serial_number,
        m.invoice_number,
        m.issuance_date,
        m.plant_code,
        m.released_by,
        m.release_reason
    FROM bp_datalake.bronze_vehicle_release_manual_release AS m
    WHERE m.is_active = 'YES';


    /*
    ============================================================
    05. AVALIAÇÃO DAS REGRAS (foto desta execução)
    Feita em etapas (tabelas temporárias) porque cada etapa usa
    colunas calculadas na anterior.
    ============================================================
    */

    -- 05.1 Fatos de cada NF: Gold + fontes auxiliares.
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

        IF(rt.customer_cnpj IS NOT NULL, 'YES', 'NO') AS is_rental_company,
        IF(f.chassis IS NOT NULL, 'YES', 'NO') AS finance_base_found,
        IF(l.chassis IS NOT NULL, 'YES', 'NO') AS legacy_released,
        IF(m.chassis IS NOT NULL, 'YES', 'NO') AS manual_released,
        m.released_by AS manual_released_by,
        m.release_reason AS manual_release_reason,

        COALESCE(c.match_count, 0) AS crm_match_count,
        c.order_no AS crm_order_no,
        c.order_status AS crm_order_status,
        c.order_sub_status AS crm_order_sub_status,
        c.vehicle_model_code AS crm_vehicle_model_code,
        c.config_no AS crm_config_no,
        c.exterior_color_code AS crm_exterior_color_code,
        c.interior_color_code AS crm_interior_color_code

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_cond_pagamento AS d
        ON d.cond_pgto_sap = g.payment_condition

    LEFT JOIN tmp_vr_rental AS rt
        ON rt.customer_cnpj = g.sold_to_party_cnpj

    LEFT JOIN tmp_vr_finance AS f
        ON  f.chassis = g.chassis_serial_number
        AND f.invoice_number = g.invoice_number
        AND f.issuance_date = g.issuance_date

    LEFT JOIN tmp_vr_legacy_released AS l
        ON  l.chassis = g.chassis_serial_number
        AND l.invoice_number = g.invoice_number
        AND l.issuance_date = g.issuance_date

    LEFT JOIN tmp_vr_manual AS m
        ON  m.chassis = g.chassis_serial_number
        AND m.invoice_number = g.invoice_number
        AND m.issuance_date = g.issuance_date
        AND m.plant_code = g.plant_code

    LEFT JOIN tmp_vr_crm AS c
        ON  c.vin = g.chassis_serial_number
        AND c.invoice_number = g.invoice_number
        AND c.invoice_date = g.issuance_date

    WHERE g.record_source = 'ZSDBIL17_CURRENT'
      AND (
          g.division IN ('B1', 'B2')
          -- Locadora: Venda Direta de CNPJ cadastrado (Grupo 1).
          OR (g.division = 'B5' AND rt.customer_cnpj IS NOT NULL)
      )
      AND g.issuance_date >= c_start_issuance_date
      AND g.plant_code IS NOT NULL;

    SET v_gold_rows = (SELECT COUNT(*) FROM tmp_vr_eval);

    -- 05.2 Indicadores usados pelas regras.
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_flags;
    CREATE TEMPORARY TABLE tmp_vr_flags AS
    SELECT
        e.*,

        -- Regra do prazo vale para Revenda/Test Drive e, enquanto a
        -- chave estiver ligada, para locadora.
        IF(e.is_rental_company = 'NO' OR c_rental_requires_payment_term = 1,
           'YES', 'NO') AS payment_term_applies,

        IF(e.payment_term_days > 30, 'YES', 'NO') AS payment_term_ok,

        -- Liberado no CRM: o BP já moveu o pedido para Pending Factory
        -- Release (ou ele já saiu da fábrica / chegou).
        IF(e.crm_match_count = 1
           AND (e.crm_order_sub_status = 'Pending Factory Release'
                OR e.crm_order_status IN ('To Be Received', 'Completed')),
           'YES', 'NO') AS crm_released

    FROM tmp_vr_eval AS e;

    -- 05.3 Status base (sem a comparação com a foto do CRM).
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_source;
    CREATE TEMPORARY TABLE tmp_vr_source AS
    SELECT
        x.*,

        CASE
            WHEN x.legacy_released = 'YES' THEN 'RELEASED'
            WHEN x.manual_released = 'YES' THEN 'RELEASED'
            WHEN x.crm_released = 'YES' THEN 'RELEASED'
            WHEN x.payment_term_applies = 'YES' AND x.payment_term_ok = 'NO'
                THEN 'REVIEW_PAYMENT_TERM'
            WHEN x.finance_base_found = 'NO' THEN 'WAITING_FINANCE'
            WHEN x.crm_match_count <> 1
              OR x.crm_order_sub_status IS NULL
              OR x.crm_order_sub_status <> 'To Be Shipped'
                THEN 'WAITING_CRM'
            ELSE 'READY_TO_RELEASE'
        END AS base_status,

        CASE
            WHEN x.legacy_released = 'YES' THEN 'LEGACY_HISTORY'
            WHEN x.manual_released = 'YES' THEN 'APP'
            WHEN x.crm_released = 'YES' THEN 'CRM_STATUS'
        END AS released_source,

        CASE
            WHEN x.legacy_released = 'YES'
                THEN 'Liberado no controle manual (planilha antiga)'
            WHEN x.manual_released = 'YES'
                THEN LEFT(CONCAT('Liberado no app por ', x.manual_released_by,
                                 ': ', x.manual_release_reason), 500)
            WHEN x.crm_released = 'YES'
                THEN CONCAT('Liberado no CRM: ',
                            IFNULL(x.crm_order_sub_status, x.crm_order_status))
            ELSE NULLIF(
                CONCAT_WS('; ',
                    CASE
                        WHEN x.payment_term_applies = 'NO' THEN NULL
                        WHEN x.payment_term_days IS NULL
                            THEN CONCAT('Condição ', IFNULL(x.payment_condition, '(vazia)'), ' sem prazo em dias')
                        WHEN x.payment_term_days <= 30
                            THEN CONCAT('Prazo de ', x.payment_term_days, ' dias (precisa ser maior que 30)')
                    END,
                    IF(x.finance_base_found = 'NO',
                        'Chave chassi + NF + data não consta na BASE do financeiro', NULL),
                    CASE
                        WHEN x.crm_match_count = 0
                            THEN 'Pedido não encontrado no CRM (chassi + NF + data)'
                        WHEN x.crm_match_count > 1
                            THEN 'Mais de um pedido no CRM para a mesma NF'
                        WHEN IFNULL(x.crm_order_sub_status, '') <> 'To Be Shipped'
                            THEN CONCAT('CRM ainda não está em To Be Shipped (',
                                        IFNULL(x.crm_order_sub_status, 'sem sub-status'), ')')
                    END
                ),
                ''
            )
        END AS base_reason,

        -- Controle: o CRM liberou sem cumprir as regras do app.
        CASE
            WHEN x.legacy_released = 'NO'
             AND x.manual_released = 'NO'
             AND x.crm_released = 'YES'
                THEN NULLIF(
                    CONCAT_WS('; ',
                        IF(x.finance_base_found = 'NO',
                            'Liberado no CRM sem a NF na BASE do Financeiro', NULL),
                        IF(x.payment_term_applies = 'YES' AND x.payment_term_ok = 'NO',
                            CONCAT('Liberado no CRM com prazo ',
                                   IFNULL(CONCAT(x.payment_term_days, ' dias'), 'sem dias'),
                                   ' (precisa ser maior que 30)'),
                            NULL)
                    ),
                    ''
                )
        END AS control_alert

    FROM tmp_vr_flags AS x;

    ALTER TABLE tmp_vr_source
        ADD PRIMARY KEY (chassis_serial_number, invoice_number, issuance_date, plant_code);

    -- 05.4 Foto do CRM: mantém a congelada ou congela agora, e
    -- compara o CRM atual com ela.
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_drift;
    CREATE TEMPORARY TABLE tmp_vr_drift AS
    SELECT
        s.*,

        IF(r.crm_snapshot_at IS NULL
           AND s.base_status IN ('READY_TO_RELEASE', 'RELEASED')
           AND s.crm_match_count = 1,
           'YES', 'NO') AS freeze_snapshot,

        r.crm_snapshot_order_no AS prev_snapshot_order_no,
        r.crm_snapshot_order_status AS prev_snapshot_order_status,
        r.crm_snapshot_order_sub_status AS prev_snapshot_order_sub_status,
        r.crm_snapshot_vehicle_model_code AS prev_snapshot_vehicle_model_code,
        r.crm_snapshot_config_no AS prev_snapshot_config_no,
        r.crm_snapshot_exterior_color_code AS prev_snapshot_exterior_color_code,
        r.crm_snapshot_interior_color_code AS prev_snapshot_interior_color_code,
        r.crm_snapshot_at AS prev_snapshot_at,

        CASE
            -- Sem foto e sem congelar agora: nada a comparar. Ao
            -- congelar, só o status de exceção já vale (o resto é igual).
            WHEN r.crm_snapshot_at IS NULL
             AND NOT (s.base_status IN ('READY_TO_RELEASE', 'RELEASED')
                      AND s.crm_match_count = 1)
                THEN NULL
            ELSE NULLIF(LEFT(
                CONCAT_WS('; ',
                    CASE
                        WHEN r.crm_snapshot_at IS NULL THEN NULL
                        WHEN s.crm_match_count = 0
                            THEN 'Pedido não aparece mais no CRM'
                        WHEN s.crm_match_count > 1
                            THEN 'A NF passou a ter mais de um pedido no CRM'
                    END,
                    IF(s.crm_match_count = 1
                       AND r.crm_snapshot_at IS NOT NULL
                       AND NOT (s.crm_order_no <=> r.crm_snapshot_order_no),
                       CONCAT('Pedido ', IFNULL(r.crm_snapshot_order_no, 'vazio'),
                              ' → ', IFNULL(s.crm_order_no, 'vazio')),
                       NULL),
                    IF(s.crm_match_count = 1
                       AND r.crm_snapshot_at IS NOT NULL
                       AND NOT (s.crm_vehicle_model_code <=> r.crm_snapshot_vehicle_model_code),
                       CONCAT('Modelo ', IFNULL(r.crm_snapshot_vehicle_model_code, 'vazio'),
                              ' → ', IFNULL(s.crm_vehicle_model_code, 'vazio')),
                       NULL),
                    IF(s.crm_match_count = 1
                       AND r.crm_snapshot_at IS NOT NULL
                       AND NOT (s.crm_config_no <=> r.crm_snapshot_config_no),
                       CONCAT('Versão (config) ', IFNULL(r.crm_snapshot_config_no, 'vazia'),
                              ' → ', IFNULL(s.crm_config_no, 'vazia')),
                       NULL),
                    IF(s.crm_match_count = 1
                       AND r.crm_snapshot_at IS NOT NULL
                       AND NOT (s.crm_exterior_color_code <=> r.crm_snapshot_exterior_color_code),
                       CONCAT('Cor externa ', IFNULL(r.crm_snapshot_exterior_color_code, 'vazia'),
                              ' → ', IFNULL(s.crm_exterior_color_code, 'vazia')),
                       NULL),
                    IF(s.crm_match_count = 1
                       AND r.crm_snapshot_at IS NOT NULL
                       AND NOT (s.crm_interior_color_code <=> r.crm_snapshot_interior_color_code),
                       CONCAT('Cor interna ', IFNULL(r.crm_snapshot_interior_color_code, 'vazia'),
                              ' → ', IFNULL(s.crm_interior_color_code, 'vazia')),
                       NULL),
                    -- Status que voltou na sequência normal do pedido.
                    IF(s.crm_match_count = 1
                       AND FIELD(s.crm_order_sub_status,
                                 'Allocated', 'SAP Processing', 'To Be Shipped',
                                 'Pending Factory Release', 'Left Factory',
                                 'Arrived', 'Returned') > 0
                       AND FIELD(r.crm_snapshot_order_sub_status,
                                 'Allocated', 'SAP Processing', 'To Be Shipped',
                                 'Pending Factory Release', 'Left Factory',
                                 'Arrived', 'Returned')
                         > FIELD(s.crm_order_sub_status,
                                 'Allocated', 'SAP Processing', 'To Be Shipped',
                                 'Pending Factory Release', 'Left Factory',
                                 'Arrived', 'Returned'),
                       CONCAT('Status voltou: ', r.crm_snapshot_order_sub_status,
                              ' → ', s.crm_order_sub_status),
                       NULL),
                    -- Cancelamento, devolução/troca ou erro no CRM.
                    IF(s.crm_match_count = 1
                       AND (s.crm_order_sub_status IN ('Invoice Cancelling',
                                                       'Allocation Cancelling',
                                                       'Special Error')
                            OR s.crm_order_status = 'Return/Exchange Processing'),
                       CONCAT('Pedido em exceção no CRM: ', s.crm_order_sub_status),
                       NULL)
                ),
                500), '')
        END AS crm_change_alert

    FROM tmp_vr_source AS s
    LEFT JOIN bp_datalake.bronze_vehicle_release AS r
        ON  r.chassis_serial_number = s.chassis_serial_number
        AND r.invoice_number = s.invoice_number
        AND r.issuance_date = s.issuance_date
        AND r.plant_code = s.plant_code;

    -- 05.5 Status final e foto a gravar.
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_final;
    CREATE TEMPORARY TABLE tmp_vr_final AS
    SELECT
        d.*,

        -- Pedido alterado bloqueia só quem ia ser liberado; liberado
        -- continua liberado (não há o que travar) e fica com o alerta.
        IF(d.crm_change_alert IS NOT NULL AND d.base_status = 'READY_TO_RELEASE',
           'CRM_CHANGED', d.base_status) AS release_status,

        IF(d.crm_change_alert IS NOT NULL AND d.base_status = 'READY_TO_RELEASE',
           LEFT(CONCAT('Pedido alterado no CRM depois da validação: ',
                       d.crm_change_alert), 500),
           d.base_reason) AS release_status_reason,

        IF(d.freeze_snapshot = 'YES', d.crm_order_no, d.prev_snapshot_order_no) AS snapshot_order_no,
        IF(d.freeze_snapshot = 'YES', d.crm_order_status, d.prev_snapshot_order_status) AS snapshot_order_status,
        IF(d.freeze_snapshot = 'YES', d.crm_order_sub_status, d.prev_snapshot_order_sub_status) AS snapshot_order_sub_status,
        IF(d.freeze_snapshot = 'YES', d.crm_vehicle_model_code, d.prev_snapshot_vehicle_model_code) AS snapshot_vehicle_model_code,
        IF(d.freeze_snapshot = 'YES', d.crm_config_no, d.prev_snapshot_config_no) AS snapshot_config_no,
        IF(d.freeze_snapshot = 'YES', d.crm_exterior_color_code, d.prev_snapshot_exterior_color_code) AS snapshot_exterior_color_code,
        IF(d.freeze_snapshot = 'YES', d.crm_interior_color_code, d.prev_snapshot_interior_color_code) AS snapshot_interior_color_code,
        IF(d.freeze_snapshot = 'YES', v_now, d.prev_snapshot_at) AS snapshot_at

    FROM tmp_vr_drift AS d;

    ALTER TABLE tmp_vr_final
        ADD PRIMARY KEY (chassis_serial_number, invoice_number, issuance_date, plant_code);


    /*
    ============================================================
    06. GRAVAÇÃO (transação única)
    ============================================================
    */

    START TRANSACTION;

    -- 06.1 Eventos: NF nova, status diferente ou alerta diferente do
    -- atual, com a foto do que o app viu (CRM, BASE, prazo, cliente).
    INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
        run_id, triggered_by,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        change_type, old_status, new_status, status_reason,
        is_rental_company, sold_to_party_cnpj, total_amount, payment_term_days,
        finance_base_found, finance_base_loaded_at,
        crm_match_count, crm_order_no, crm_order_status, crm_order_sub_status, crm_loaded_at,
        control_alert, crm_change_alert,
        changed_at
    )
    SELECT
        p_run_id,
        TRIM(p_triggered_by),
        s.chassis_serial_number,
        s.invoice_number,
        s.issuance_date,
        s.plant_code,
        CASE
            WHEN r.id IS NULL THEN 'INSERTED'
            WHEN r.release_status <> s.release_status THEN 'STATUS_CHANGED'
            ELSE 'ALERT_CHANGED'
        END,
        r.release_status,
        s.release_status,
        s.release_status_reason,
        s.is_rental_company,
        s.sold_to_party_cnpj,
        s.total_amount,
        s.payment_term_days,
        s.finance_base_found,
        v_finance_last_load,
        LEAST(s.crm_match_count, 127),
        s.crm_order_no,
        s.crm_order_status,
        s.crm_order_sub_status,
        v_crm_last_load,
        s.control_alert,
        s.crm_change_alert,
        v_now
    FROM tmp_vr_final AS s
    LEFT JOIN bp_datalake.bronze_vehicle_release AS r
        ON  r.chassis_serial_number = s.chassis_serial_number
        AND r.invoice_number = s.invoice_number
        AND r.issuance_date = s.issuance_date
        AND r.plant_code = s.plant_code
    WHERE r.id IS NULL
       OR r.release_status <> s.release_status
       OR NOT (r.control_alert <=> s.control_alert)
       OR NOT (r.crm_change_alert <=> s.crm_change_alert);

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
        crm_match_count, crm_order_no, crm_order_status, crm_order_sub_status,
        crm_vehicle_model_code, crm_config_no, crm_exterior_color_code, crm_interior_color_code,
        crm_loaded_at,
        crm_snapshot_order_no, crm_snapshot_order_status, crm_snapshot_order_sub_status,
        crm_snapshot_vehicle_model_code, crm_snapshot_config_no,
        crm_snapshot_exterior_color_code, crm_snapshot_interior_color_code,
        crm_snapshot_at, crm_change_alert,
        release_status, release_status_reason, released_source, control_alert, in_gold,
        status_since, first_seen_at, last_run_id
    )
    SELECT
        s.chassis_serial_number, s.invoice_number, s.issuance_date, s.plant_code, s.proc_time,
        s.division, s.division_description, 'GROUP_1', s.is_rental_company,
        s.sold_to_party_code, s.sold_to_party_cnpj, s.sold_to_party_name,
        s.ship_to_party_code, s.ship_to_party_cnpj, s.ship_to_party_name,
        s.dealer_group, s.store_name_crm,
        s.material, s.model_simplified,
        s.total_amount, s.payment_condition, s.payment_term_days, s.payment_term_ok,
        s.finance_base_found, v_finance_last_load,
        LEAST(s.crm_match_count, 127), s.crm_order_no, s.crm_order_status, s.crm_order_sub_status,
        s.crm_vehicle_model_code, s.crm_config_no, s.crm_exterior_color_code, s.crm_interior_color_code,
        v_crm_last_load,
        s.snapshot_order_no, s.snapshot_order_status, s.snapshot_order_sub_status,
        s.snapshot_vehicle_model_code, s.snapshot_config_no,
        s.snapshot_exterior_color_code, s.snapshot_interior_color_code,
        s.snapshot_at, s.crm_change_alert,
        s.release_status, s.release_status_reason, s.released_source, s.control_alert, 'YES',
        v_now, v_now, p_run_id
    FROM tmp_vr_final AS s
    ON DUPLICATE KEY UPDATE
        status_since = IF(
            bronze_vehicle_release.release_status <> s.release_status,
            v_now,
            bronze_vehicle_release.status_since
        ),
        proc_time = s.proc_time,
        division = s.division,
        division_description = s.division_description,
        is_rental_company = s.is_rental_company,
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
        crm_vehicle_model_code = s.crm_vehicle_model_code,
        crm_config_no = s.crm_config_no,
        crm_exterior_color_code = s.crm_exterior_color_code,
        crm_interior_color_code = s.crm_interior_color_code,
        crm_loaded_at = v_crm_last_load,
        crm_snapshot_order_no = s.snapshot_order_no,
        crm_snapshot_order_status = s.snapshot_order_status,
        crm_snapshot_order_sub_status = s.snapshot_order_sub_status,
        crm_snapshot_vehicle_model_code = s.snapshot_vehicle_model_code,
        crm_snapshot_config_no = s.snapshot_config_no,
        crm_snapshot_exterior_color_code = s.snapshot_exterior_color_code,
        crm_snapshot_interior_color_code = s.snapshot_interior_color_code,
        crm_snapshot_at = s.snapshot_at,
        crm_change_alert = s.crm_change_alert,
        release_status = s.release_status,
        release_status_reason = s.release_status_reason,
        released_source = s.released_source,
        control_alert = s.control_alert,
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
          FROM tmp_vr_final AS s
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
            SUM(release_status = 'NOT_IN_GOLD') AS qty_not_in_gold,
            SUM(release_status = 'CRM_CHANGED') AS qty_crm_changed,
            SUM(in_gold = 'YES'
                AND (control_alert IS NOT NULL OR crm_change_alert IS NOT NULL)) AS qty_with_alert,
            SUM(in_gold = 'YES' AND is_rental_company = 'YES') AS qty_rental
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
        run.qty_crm_changed = COALESCE(totals.qty_crm_changed, 0),
        run.qty_with_alert = COALESCE(totals.qty_with_alert, 0),
        run.qty_rental_company = COALESCE(totals.qty_rental, 0),
        run.crm_last_load_at = v_crm_last_load,
        run.crm_is_fresh = IF(DATE(v_crm_last_load) = CURDATE(), 'YES', 'NO'),
        run.finance_base_last_load_at = v_finance_last_load,
        run.finance_base_rows = v_finance_rows
    WHERE run.run_id = p_run_id;

    COMMIT;

    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

    DROP TEMPORARY TABLE IF EXISTS tmp_vr_final;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_drift;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_source;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_flags;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_eval;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_crm;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_finance;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_legacy_released;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_rental;
    DROP TEMPORARY TABLE IF EXISTS tmp_vr_manual;

END$$

DELIMITER ;
