
-- ============================================================
-- GOLD - MODEL ENRICHMENT
-- ============================================================
-- Objetivo:
-- Atualizar o modelo simplificado dos veículos na Gold.
--
-- Origem:
-- bp_datalake.bronze_vehicle_material_code
--
-- Relacionamento:
-- gold.material -> bronze_vehicle_material_code.cod_sap
--
-- Destino:
-- gold.model_simplified
--
-- Estratégia:
-- Reconsulta todos os materiais da Gold.
-- Atualiza somente quando o modelo encontrado for diferente
-- do atual, incluindo valores NULL ou UNKNOWN.
--
-- Sem correspondência válida, utiliza UNKNOWN.
-- Considera registros atuais e Legacy.
-- ============================================================

DELIMITER $$

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_enrich_model$$

CREATE PROCEDURE bp_datalake.sp_gold_z17_enrich_model()
BEGIN

    -- ========================================================
    -- 1. VARIÁVEIS
    -- ========================================================

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_model_match BIGINT DEFAULT 0;
    DECLARE v_unmatched_rows BIGINT DEFAULT 0;
    DECLARE v_rows_updated BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    -- ========================================================
    -- 2. TRATAMENTO DE ERROS
    -- ========================================================

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

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
            'sp_gold_z17_enrich_model',
            'bronze_vehicle_material_code',
            'gold_zsdbil17_faturamento',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_model_match,
            0,
            v_rows_updated,
            v_unmatched_rows,
            v_error_code,
            v_error_message,
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000
        );

        COMMIT;
        RESIGNAL;

    END;


    SET v_started_at = NOW(6);


    -- ========================================================
    -- 3. GARANTE A COLUNA MODEL_SIMPLIFIED
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_faturamento'
          AND column_name = 'model_simplified'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_faturamento
            ADD COLUMN model_simplified VARCHAR(100) NULL
            AFTER material;

    END IF;


    START TRANSACTION;


    -- ========================================================
    -- 4. TOTAL DE REGISTROS DA GOLD
    -- ========================================================

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento;


    -- ========================================================
    -- 5. REGISTROS COM MODELO IDENTIFICADO
    -- ========================================================

    SELECT COUNT(*)
    INTO v_model_match

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    WHERE EXISTS (

        SELECT 1
        FROM bp_datalake.bronze_vehicle_material_code AS mm

        WHERE NULLIF(
            TRIM(CAST(mm.cod_sap AS CHAR)), ''
        ) IS NOT NULL

        AND
            CONVERT(
                TRIM(CAST(mm.cod_sap AS CHAR))
                USING utf8mb4
            ) COLLATE utf8mb4_unicode_ci
            =
            CONVERT(
                TRIM(CAST(g.material AS CHAR))
                USING utf8mb4
            ) COLLATE utf8mb4_unicode_ci

        AND NULLIF(
            TRIM(mm.model_simplified), ''
        ) IS NOT NULL

    );


    SET v_unmatched_rows =
        v_source_rows - v_model_match;


    -- ========================================================
    -- 6. ENRIQUECIMENTO DO MODELO
    -- ========================================================
    /*
    Busca o modelo atualizado na Bronze.

    Se houver mais de um cod_sap, seleciona apenas
    um registro, priorizando modelo preenchido.

    Atualiza a Gold somente quando o valor for diferente.

    A comparação usa a mesma collation nos dois lados.
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN (

        SELECT
            ranked.cod_sap,
            ranked.model_simplified

        FROM (

            SELECT
                mm.cod_sap,
                mm.model_simplified,

                ROW_NUMBER() OVER (

                    PARTITION BY
                        TRIM(CAST(mm.cod_sap AS CHAR))

                    ORDER BY
                        CASE
                            WHEN NULLIF(
                                TRIM(mm.model_simplified), ''
                            ) IS NOT NULL
                                THEN 1
                            ELSE 2
                        END,

                        COALESCE(
                            TRIM(mm.model_simplified), ''
                        )

                ) AS rn

            FROM bp_datalake.bronze_vehicle_material_code AS mm

            WHERE NULLIF(
                TRIM(CAST(mm.cod_sap AS CHAR)), ''
            ) IS NOT NULL

        ) AS ranked

        WHERE ranked.rn = 1

    ) AS mm

        ON
            CONVERT(
                TRIM(CAST(g.material AS CHAR))
                USING utf8mb4
            ) COLLATE utf8mb4_unicode_ci
            =
            CONVERT(
                TRIM(CAST(mm.cod_sap AS CHAR))
                USING utf8mb4
            ) COLLATE utf8mb4_unicode_ci


    SET
        g.model_simplified =
            COALESCE(
                NULLIF(TRIM(mm.model_simplified), ''),
                'UNKNOWN'
            )


    -- ========================================================
    -- 6.1 ATUALIZA SOMENTE VALORES DIFERENTES
    -- ========================================================

    WHERE NOT (

        CONVERT(
            g.model_simplified USING utf8mb4
        ) COLLATE utf8mb4_unicode_ci

        <=>

        CONVERT(
            COALESCE(
                NULLIF(TRIM(mm.model_simplified), ''),
                'UNKNOWN'
            )
            USING utf8mb4
        ) COLLATE utf8mb4_unicode_ci

    );


    SET v_rows_updated = ROW_COUNT();


    -- ========================================================
    -- 7. FINALIZAÇÃO
    -- ========================================================

    SET v_finished_at = NOW(6);


    -- ========================================================
    -- 8. LOG DE SUCESSO
    -- ========================================================

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
        'sp_gold_z17_enrich_model',
        'bronze_vehicle_material_code',
        'gold_zsdbil17_faturamento',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_model_match,
        0,
        v_rows_updated,
        v_unmatched_rows,
        NULL,
        NULL,
        TIMESTAMPDIFF(
            MICROSECOND,
            v_started_at,
            v_finished_at
        ) / 1000000
    );


    -- ========================================================
    -- 9. CONFIRMA TRANSAÇÃO
    -- ========================================================

    COMMIT;


    -- ========================================================
    -- 10. RESULTADO DA EXECUÇÃO
    -- ========================================================

    SELECT
        'SUCCESS' AS execution_status,

        v_source_rows AS source_rows,
        v_model_match AS model_match_rows,
        v_unmatched_rows AS unmatched_rows,
        v_rows_updated AS model_updated_rows,

        v_model_match + v_unmatched_rows AS accounted_rows,

        ROUND(
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
            2
        ) AS execution_duration_seconds,

        v_started_at AS started_at,
        v_finished_at AS finished_at;

END$$

DELIMITER ;
    