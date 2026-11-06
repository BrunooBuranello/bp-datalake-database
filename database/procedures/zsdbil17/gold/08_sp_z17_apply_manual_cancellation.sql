-- ============================================================
-- ZSDBIL17 - GOLD
-- 08 - APLICAÇÃO DO CANCELAMENTO MANUAL (PALIATIVO)
-- ============================================================
-- Objetivo:
-- Tirar da Gold de faturamento as NFs registradas no app de
-- cancelamentos (dim_zsdbil17_manual_cancellation) e marcar
-- essas NFs na Silver.
--
-- Posição na pipeline:
-- Depois de sp_gold_z17_enrich_model (Gold completa, CURRENT
-- e LEGACY) e antes do DEMO History.
--
-- Por que uma procedure separada, no fim, e não um filtro no
-- sp_gold_z17_load_base:
-- 1. Independência: load_base e append_legacy não mudam. Para
--    desligar o paliativo basta remover o CALL da pipeline; a
--    próxima carga recria a Gold inteira sem exclusão.
-- 2. Sem fallback: se o filtro ficasse antes do ranking, a NF
--    anterior do chassi viraria a "mais recente" e entraria; se
--    ficasse no load_base, o append_legacy (NOT EXISTS contra a
--    Gold) colocaria a NF legacy do chassi. Apagando no fim, o
--    chassi simplesmente fica fora, como já acontece com uma NF
--    CANCELLED.
--
-- Regras:
-- 1. Chave = chassi + NF, só registros active = 1.
-- 2. Silver: manual_cancellation = 'YES' e manual_cancelled_at
--    = loaded_at nas linhas da chave; 'NO' e NULL nas demais.
--    Recalculado a cada execução porque a Silver é incremental
--    (linhas reinseridas voltam com NULL) e porque um registro
--    desativado precisa voltar para 'NO'. Só linhas cujo valor
--    muda são atualizadas.
-- 3. Gold: DELETE das linhas da chave.
-- 4. DEMO History não usa estas colunas (decisão de 06/11/2026;
--    ver docs/DECISIONS.md do app cancellations).
--
-- Erro:
-- Faz ROLLBACK, grava ERROR no etl_execution_log e NÃO relança
-- o erro: a pipeline continua e o relatório de faturamento do
-- dia sai, só que sem a exclusão manual naquele dia. A Gold
-- fica exatamente como o load_base deixou.
--
-- Idempotente: rodar duas vezes dá o mesmo resultado.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_z17_apply_manual_cancellation;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_z17_apply_manual_cancellation()
BEGIN

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    -- Registros ativos na tabela manual.
    DECLARE v_active_cancellations BIGINT DEFAULT 0;

    -- Linhas da Silver alteradas (YES <-> NO).
    DECLARE v_silver_rows_updated BIGINT DEFAULT 0;

    -- Linhas da Silver marcadas como YES depois da execução.
    DECLARE v_silver_rows_marked BIGINT DEFAULT 0;

    -- Linhas removidas da Gold.
    DECLARE v_gold_rows_deleted BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    TRATAMENTO DE ERRO
    ============================================================
    Sem RESIGNAL de propósito: o paliativo não pode parar a
    pipeline (ver cabeçalho).
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_manual_cancellation;

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
            'sp_z17_apply_manual_cancellation',
            'dim_zsdbil17_manual_cancellation',
            'gold_zsdbil17_faturamento',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_active_cancellations,
            0,
            0,
            0,
            0,
            v_error_code,
            v_error_message,
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
        );

        COMMIT;

        SELECT
            'ERROR' AS execution_status,
            v_error_code AS error_code,
            v_error_message AS error_message;

    END;


    SET v_started_at = NOW(6);


    /*
    ============================================================
    1. GARANTE AS COLUNAS NA SILVER
    ============================================================
    DDL antes da transação, porque ALTER TABLE faz commit
    implícito. Só executa na primeira vez; depois o IF é falso.
    Mesmo padrão da sp_gold_z17_demo_apply_campaign.
    */

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'silver_zsdbil17_outbound_movements'
          AND column_name = 'manual_cancellation'
    ) THEN

        ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
            ADD COLUMN manual_cancellation VARCHAR(3) NULL
                COMMENT 'YES = NF cancelada manualmente no app de cancelamentos; NO = não',
            ADD COLUMN manual_cancelled_at DATETIME NULL
                COMMENT 'Data e hora em que o cancelamento manual foi registrado (loaded_at)';

    END IF;


    /*
    ============================================================
    2. CANCELAMENTOS ATIVOS
    ============================================================
    Tabela temporária com collation explícita: as comparações
    com Silver e Gold usam a mesma collation e não falham com
    erro 1267 (tabelas criadas em momentos diferentes).
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_manual_cancellation;

    CREATE TEMPORARY TABLE tmp_z17_manual_cancellation AS
    SELECT
        CONVERT(TRIM(c.chassis_serial_number) USING utf8mb4)
            COLLATE utf8mb4_0900_ai_ci AS chassis_serial_number,
        CONVERT(TRIM(c.invoice_number) USING utf8mb4)
            COLLATE utf8mb4_0900_ai_ci AS invoice_number,
        c.loaded_at
    FROM bp_datalake.dim_zsdbil17_manual_cancellation AS c
    WHERE c.active = 1;

    SELECT COUNT(*)
    INTO v_active_cancellations
    FROM tmp_z17_manual_cancellation;


    START TRANSACTION;


    /*
    ============================================================
    3. SILVER - MARCAÇÃO
    ============================================================
    Um único UPDATE calcula o valor esperado de cada linha
    (YES quando a chave está na lista, NO caso contrário) e
    só grava onde o valor atual é diferente. <=> compara NULL
    com segurança.
    A UNIQUE (chassi, NF) da tabela manual garante no máximo
    uma correspondência por linha da Silver.
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s
    LEFT JOIN tmp_z17_manual_cancellation AS c
        ON c.chassis_serial_number =
               CONVERT(TRIM(s.chassis_serial_number) USING utf8mb4)
                   COLLATE utf8mb4_0900_ai_ci
       AND c.invoice_number =
               CONVERT(TRIM(s.invoice_number) USING utf8mb4)
                   COLLATE utf8mb4_0900_ai_ci
    SET
        s.manual_cancellation =
            CASE WHEN c.chassis_serial_number IS NULL THEN 'NO' ELSE 'YES' END,
        s.manual_cancelled_at = c.loaded_at
    WHERE
        NOT (
            s.manual_cancellation <=>
                CASE WHEN c.chassis_serial_number IS NULL THEN 'NO' ELSE 'YES' END
        )
        OR NOT (s.manual_cancelled_at <=> c.loaded_at);

    SET v_silver_rows_updated = ROW_COUNT();


    SELECT COUNT(*)
    INTO v_silver_rows_marked
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE manual_cancellation = 'YES';


    /*
    ============================================================
    4. GOLD - REMOÇÃO
    ============================================================
    A Gold já grava chassi e NF com TRIM (load_base e legacy);
    o CONVERT/COLLATE só alinha a collation com a temporária.
    */

    DELETE g
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    INNER JOIN tmp_z17_manual_cancellation AS c
        ON c.chassis_serial_number =
               CONVERT(g.chassis_serial_number USING utf8mb4)
                   COLLATE utf8mb4_0900_ai_ci
       AND c.invoice_number =
               CONVERT(g.invoice_number USING utf8mb4)
                   COLLATE utf8mb4_0900_ai_ci;

    SET v_gold_rows_deleted = ROW_COUNT();


    /*
    ============================================================
    5. LOG E CONFIRMAÇÃO
    ============================================================
    source_rows   = cancelamentos ativos
    selected_rows = linhas da Silver marcadas YES
    updated_rows  = linhas da Silver alteradas nesta execução
    rejected_rows = linhas removidas da Gold
    */

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
        'sp_z17_apply_manual_cancellation',
        'dim_zsdbil17_manual_cancellation',
        'gold_zsdbil17_faturamento',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_active_cancellations,
        v_silver_rows_marked,
        0,
        v_silver_rows_updated,
        v_gold_rows_deleted,
        NULL,
        NULL,
        TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
    );

    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_manual_cancellation;


    /*
    ============================================================
    6. RETORNO
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_active_cancellations AS active_cancellations,
        v_silver_rows_marked AS silver_rows_marked,
        v_silver_rows_updated AS silver_rows_updated,
        v_gold_rows_deleted AS gold_rows_deleted,
        ROUND(
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000,
            2
        ) AS execution_duration_seconds,
        v_started_at AS started_at,
        v_finished_at AS finished_at;

END$$

DELIMITER ;
