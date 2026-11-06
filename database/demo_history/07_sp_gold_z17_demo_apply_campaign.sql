-- ============================================================
-- ZSDBIL17 - DEMO HISTORY
-- 07 - APLICAÇÃO DE CAMPANHAS NO CICLO DEMO
-- ============================================================
-- Objetivo:
-- Aplicar as campanhas de bp_datalake.dim_demo_campaign sobre
-- a gold_zsdbil17_demo_history.
--
-- Por que uma procedure separada:
-- A sp_sync_gold_zsdbil17_demo_history continua calculando o
-- prazo padrão (aviso +20, vencimento +30) para todos os
-- ciclos e reescreve warning_date, due_date e demo_status a
-- cada execução. Esta procedure roda logo depois do
-- enriquecimento de modelo (a campanha depende do
-- model_simplified) e sobrescreve só os ciclos elegíveis.
-- Assim a regra padrão fica intocada e, quando uma campanha
-- deixa de valer, o ciclo volta sozinho ao padrão.
--
-- Identidade do ciclo:
-- chassis_serial_number + demo_origin_invoice_number (mesma
-- chave do idx_demo_sequence). Todas as linhas do ciclo
-- recebem as mesmas datas e o mesmo status.
--
-- Regras:
-- 1. Elegibilidade e desempate: ver 06_create_dim_demo_campaign.
-- 2. Datas: emissão do DEMO + warning_days / due_days.
-- 3. Status: CLOSED é terminal e nunca muda. Os demais são
--    recalculados com a mesma régua da sync:
--      hoje >  vencimento -> OVERDUE
--      hoje >= aviso      -> WARNING
--      senão              -> OPEN
--    Um ciclo OVERDUE pelo padrão pode voltar a WARNING.
-- 4. Ciclos CLOSED elegíveis também recebem as datas e as
--    colunas campaign_*, para o histórico mostrar o prazo
--    que valia para eles.
-- 5. Ciclos que deixaram de ser elegíveis têm as colunas
--    campaign_* limpas (as datas já voltaram ao padrão na sync).
-- 6. warning_sent_at e overdue_sent_at pertencem ao app e
--    não são alterados.
-- 7. Campanha por lista (match_type = 'CHASSIS_LIST', script
--    08): vale para os chassis de dim_demo_campaign_chassis,
--    só em ciclos não CLOSED, sem olhar modelo.
-- 8. Vencimento: fixed_due_date quando preenchido; senão
--    emissão + due_days. O aviso nunca fica depois do
--    vencimento (LEAST).
-- 9. Vigência (valid_from/valid_to, pela data de hoje): fora
--    dela a campanha não se aplica e o ciclo volta ao padrão
--    na mesma execução (regra 5).
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_demo_apply_campaign;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_gold_z17_demo_apply_campaign()
BEGIN

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_active_campaigns BIGINT DEFAULT 0;
    DECLARE v_matched_cycles BIGINT DEFAULT 0;
    DECLARE v_status_changes BIGINT DEFAULT 0;
    DECLARE v_rows_updated BIGINT DEFAULT 0;
    DECLARE v_rows_cleared BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    TRATAMENTO DE ERRO
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_demo_campaign_match;

        SET v_finished_at = NOW(6);

        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name,
            source_table,
            target_table,
            execution_status,
            executed_by,
            started_at,
            finished_at,
            source_rows,
            selected_rows,
            inserted_rows,
            updated_rows,
            rejected_rows,
            error_code,
            error_message,
            execution_duration_seconds
        )
        VALUES (
            'sp_gold_z17_demo_apply_campaign',
            'dim_demo_campaign',
            'gold_zsdbil17_demo_history',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_active_campaigns,
            v_matched_cycles,
            0,
            v_rows_updated,
            v_rows_cleared,
            v_error_code,
            v_error_message,
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
        );

        COMMIT;
        RESIGNAL;

    END;


    SET v_started_at = NOW(6);


    /*
    ============================================================
    1. GARANTE AS COLUNAS DE CAMPANHA NA GOLD
    ============================================================
    Mesmo padrão do enriquecimento de modelo: DDL antes da
    transação, porque ALTER TABLE faz commit implícito.
    */

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_demo_history'
          AND column_name = 'campaign_code'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_demo_history
            ADD COLUMN campaign_code VARCHAR(50) NULL AFTER due_date,
            ADD COLUMN campaign_name VARCHAR(150) NULL AFTER campaign_code,
            ADD COLUMN campaign_warning_days SMALLINT NULL AFTER campaign_name,
            ADD COLUMN campaign_due_days SMALLINT NULL AFTER campaign_warning_days,
            ADD COLUMN campaign_applied_at DATETIME NULL AFTER campaign_due_days,
            ADD KEY idx_demo_campaign_code (campaign_code);

    END IF;


    /*
    ============================================================
    2. CAMPANHA VENCEDORA DE CADA CICLO
    ============================================================
    Usa o evento inicial (event_sequence = 1), que carrega a
    emissão e o material do DEMO. Collation explícita nas
    comparações de texto entre tabelas diferentes.
    */

    -- Ativas e dentro da vigência hoje (regra 9).
    SELECT COUNT(*)
    INTO v_active_campaigns
    FROM bp_datalake.dim_demo_campaign
    WHERE active = 1
      AND (valid_from IS NULL OR CURRENT_DATE >= valid_from)
      AND (valid_to IS NULL OR CURRENT_DATE <= valid_to);

    DROP TEMPORARY TABLE IF EXISTS tmp_demo_campaign_match;

    /*
    CREATE ... AS SELECT herda tipo e collation das colunas da
    Gold, evitando erro 1267 no JOIN de volta com a Gold.
    */
    CREATE TEMPORARY TABLE tmp_demo_campaign_match AS
    SELECT
        ranked.chassis_serial_number,
        ranked.demo_origin_invoice_number,
        ranked.demo_issuance_date,
        ranked.campaign_code,
        ranked.campaign_name,
        ranked.warning_days,
        ranked.due_days,
        -- Regra 8: o aviso nunca depois do vencimento.
        LEAST(
            DATE_ADD(ranked.demo_issuance_date, INTERVAL ranked.warning_days DAY),
            ranked.due_date
        ) AS warning_date,
        ranked.due_date
    FROM (

        SELECT
            g.chassis_serial_number,
            g.demo_origin_invoice_number,
            DATE(g.issuance_date) AS demo_issuance_date,
            c.campaign_code,
            c.campaign_name,
            c.warning_days,
            c.due_days,
            -- Regra 8: vencimento fixo vence o due_days.
            COALESCE(
                c.fixed_due_date,
                DATE_ADD(DATE(g.issuance_date), INTERVAL c.due_days DAY)
            ) AS due_date,

            ROW_NUMBER() OVER (
                PARTITION BY
                    g.chassis_serial_number,
                    g.demo_origin_invoice_number
                ORDER BY
                    c.priority DESC,
                    c.campaign_code ASC
            ) AS rn

        FROM bp_datalake.gold_zsdbil17_demo_history AS g

        INNER JOIN bp_datalake.dim_demo_campaign AS c
            ON c.active = 1
           -- Regra 9: vigência pela data de hoje.
           AND (c.valid_from IS NULL OR CURRENT_DATE >= c.valid_from)
           AND (c.valid_to IS NULL OR CURRENT_DATE <= c.valid_to)
           AND DATE(g.issuance_date) >= c.issuance_from
           AND (c.issuance_to IS NULL OR DATE(g.issuance_date) <= c.issuance_to)
           AND (
               -- Campanha por modelo (Shark): prefixo do model_simplified.
               (
                   c.match_type = 'MODEL'
                   AND CONVERT(UPPER(TRIM(g.model_simplified)) USING utf8mb4)
                           COLLATE utf8mb4_unicode_ci
                       LIKE CONCAT(
                           CONVERT(UPPER(TRIM(c.model_simplified_prefix)) USING utf8mb4)
                               COLLATE utf8mb4_unicode_ci,
                           '%'
                       )
               )
               -- Regra 7: campanha por lista, só ciclos não CLOSED.
               OR (
                   c.match_type = 'CHASSIS_LIST'
                   AND g.demo_status <> 'CLOSED'
                   AND EXISTS (
                       SELECT 1
                       FROM bp_datalake.dim_demo_campaign_chassis AS cc
                       WHERE cc.campaign_code = c.campaign_code
                         AND cc.chassis_serial_number = g.chassis_serial_number
                   )
               )
           )

        WHERE g.event_sequence = 1
          AND g.event_type = 'DEMO'
          AND g.issuance_date IS NOT NULL
          AND g.demo_origin_invoice_number IS NOT NULL

          -- Ano-modelo: só exigido quando a campanha define um.
          AND (
              c.model_year IS NULL
              OR EXISTS (
                  SELECT 1
                  FROM bp_datalake.bronze_vehicle_material_code AS mm
                  WHERE CONVERT(TRIM(CAST(mm.cod_sap AS CHAR)) USING utf8mb4)
                            COLLATE utf8mb4_unicode_ci
                      = CONVERT(TRIM(CAST(g.material AS CHAR)) USING utf8mb4)
                            COLLATE utf8mb4_unicode_ci
                    AND CONVERT(TRIM(mm.ano_modelo) USING utf8mb4)
                            COLLATE utf8mb4_unicode_ci
                      = CONVERT(TRIM(c.model_year) USING utf8mb4)
                            COLLATE utf8mb4_unicode_ci
              )
          )

    ) AS ranked

    WHERE ranked.rn = 1;

    -- rn = 1 garante um registro por ciclo; a PK acelera os JOINs.
    ALTER TABLE tmp_demo_campaign_match
        ADD PRIMARY KEY (chassis_serial_number, demo_origin_invoice_number);

    SELECT COUNT(*)
    INTO v_matched_cycles
    FROM tmp_demo_campaign_match;


    START TRANSACTION;


    /*
    ============================================================
    3. CONTAGEM DE MUDANÇAS DE STATUS (INFORMATIVA)
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_status_changes
    FROM bp_datalake.gold_zsdbil17_demo_history AS g
    INNER JOIN tmp_demo_campaign_match AS m
        ON m.chassis_serial_number = g.chassis_serial_number
       AND m.demo_origin_invoice_number = g.demo_origin_invoice_number
    WHERE g.event_sequence = 1
      AND g.demo_status <> 'CLOSED'
      AND g.demo_status <>
          CASE
              WHEN CURRENT_DATE > m.due_date THEN 'OVERDUE'
              WHEN CURRENT_DATE >= m.warning_date THEN 'WARNING'
              ELSE 'OPEN'
          END;


    /*
    ============================================================
    4. APLICA PRAZO, STATUS E CAMPANHA
    ============================================================
    campaign_applied_at vem primeiro no SET: o MySQL avalia as
    atribuições da esquerda para a direita, e a comparação
    precisa ver o campaign_code anterior. A data só muda quando
    a campanha do ciclo muda.
    */

    UPDATE bp_datalake.gold_zsdbil17_demo_history AS g
    INNER JOIN tmp_demo_campaign_match AS m
        ON m.chassis_serial_number = g.chassis_serial_number
       AND m.demo_origin_invoice_number = g.demo_origin_invoice_number
    SET
        g.campaign_applied_at =
            CASE
                WHEN CONVERT(g.campaign_code USING utf8mb4) COLLATE utf8mb4_unicode_ci
                     <=> CONVERT(m.campaign_code USING utf8mb4) COLLATE utf8mb4_unicode_ci
                    THEN COALESCE(g.campaign_applied_at, NOW())
                ELSE NOW()
            END,
        g.warning_date = m.warning_date,
        g.due_date = m.due_date,
        g.demo_status =
            CASE
                WHEN g.demo_status = 'CLOSED' THEN 'CLOSED'
                WHEN CURRENT_DATE > m.due_date THEN 'OVERDUE'
                WHEN CURRENT_DATE >= m.warning_date THEN 'WARNING'
                ELSE 'OPEN'
            END,
        g.campaign_code = m.campaign_code,
        g.campaign_name = m.campaign_name,
        g.campaign_warning_days = m.warning_days,
        g.campaign_due_days = m.due_days;

    SET v_rows_updated = ROW_COUNT();


    /*
    ============================================================
    5. LIMPA CICLOS QUE DEIXARAM DE SER ELEGÍVEIS
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_demo_history AS g
    LEFT JOIN tmp_demo_campaign_match AS m
        ON m.chassis_serial_number = g.chassis_serial_number
       AND m.demo_origin_invoice_number = g.demo_origin_invoice_number
    SET
        g.campaign_code = NULL,
        g.campaign_name = NULL,
        g.campaign_warning_days = NULL,
        g.campaign_due_days = NULL,
        g.campaign_applied_at = NULL
    WHERE g.campaign_code IS NOT NULL
      AND m.chassis_serial_number IS NULL;

    SET v_rows_cleared = ROW_COUNT();


    SET v_finished_at = NOW(6);


    /*
    ============================================================
    6. LOG DE SUCESSO
    ============================================================
    source_rows   = campanhas ativas
    selected_rows = ciclos elegíveis
    updated_rows  = linhas da Gold atualizadas
    rejected_rows = linhas com campanha removida
    */

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        finished_at,
        source_rows,
        selected_rows,
        inserted_rows,
        updated_rows,
        rejected_rows,
        error_code,
        error_message,
        execution_duration_seconds
    )
    VALUES (
        'sp_gold_z17_demo_apply_campaign',
        'dim_demo_campaign',
        'gold_zsdbil17_demo_history',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_active_campaigns,
        v_matched_cycles,
        0,
        v_rows_updated,
        v_rows_cleared,
        NULL,
        NULL,
        TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
    );


    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_demo_campaign_match;


    /*
    ============================================================
    7. RETORNO
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_active_campaigns AS active_campaigns,
        v_matched_cycles AS matched_cycles,
        v_status_changes AS status_changes,
        v_rows_updated AS rows_updated,
        v_rows_cleared AS rows_cleared,
        ROUND(
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000,
            2
        ) AS execution_duration_seconds,
        v_started_at AS started_at,
        v_finished_at AS finished_at;

END$$

DELIMITER ;
