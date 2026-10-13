-- ============================================================
-- GOLD - DEMO HISTORY - MODEL ENRICHMENT
-- ============================================================
-- Objetivo:
-- Enriquecer a gold_zsdbil17_demo_history com o modelo
-- simplificado do veículo.
--
-- Origem:
-- bp_datalake.material_master
--
-- Chave:
-- gold.material -> material_master.cod_sap
--
-- Destino:
-- model_simplified
--
-- Estratégia:
-- Utiliza o mapeamento atual existente no material_master.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_demo_enrich_model;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_gold_z17_demo_enrich_model()
BEGIN

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_model_match BIGINT DEFAULT 0;
    DECLARE v_unmatched_rows BIGINT DEFAULT 0;
    DECLARE v_rows_updated BIGINT DEFAULT 0;

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
            'sp_gold_z17_demo_enrich_model',
            'material_master',
            'gold_zsdbil17_demo_history',
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
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
        );

        COMMIT;
        RESIGNAL;

    END;


    SET v_started_at = NOW(6);


    /*
    ============================================================
    1. GARANTE COLUNA DE MODELO
    ============================================================
    */

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_demo_history'
          AND column_name = 'model_simplified'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_demo_history
            ADD COLUMN model_simplified VARCHAR(100) NULL
            AFTER material;

    END IF;


    START TRANSACTION;


    /*
    ============================================================
    2. TOTAL DE REGISTROS DA DEMO HISTORY
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_demo_history;


    /*
    ============================================================
    3. REGISTROS COM MATCH NO MATERIAL MASTER
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_model_match

    FROM bp_datalake.gold_zsdbil17_demo_history AS g

    WHERE EXISTS (
        SELECT 1
        FROM bp_datalake.material_master AS mm
        WHERE NULLIF(TRIM(CAST(mm.cod_sap AS CHAR)), '') IS NOT NULL
          AND TRIM(CAST(mm.cod_sap AS CHAR))
              = TRIM(CAST(g.material AS CHAR))
          AND NULLIF(TRIM(mm.model_simplified), '') IS NOT NULL
    );


    SET v_unmatched_rows =
        v_source_rows - v_model_match;


    /*
    ============================================================
    4. ENRIQUECIMENTO DO MODELO
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_demo_history AS g

    LEFT JOIN (

        SELECT
            ranked.cod_sap,
            ranked.model_simplified

        FROM (

            SELECT
                mm.cod_sap,
                mm.model_simplified,

                ROW_NUMBER() OVER (
                    PARTITION BY TRIM(CAST(mm.cod_sap AS CHAR))
                    ORDER BY
                        CASE
                            WHEN NULLIF(TRIM(mm.model_simplified), '') IS NOT NULL
                                THEN 1
                            ELSE 2
                        END,
                        COALESCE(TRIM(mm.model_simplified), '')
                ) AS rn

            FROM bp_datalake.material_master AS mm

            WHERE NULLIF(
                TRIM(CAST(mm.cod_sap AS CHAR)),
                ''
            ) IS NOT NULL

        ) AS ranked

        WHERE ranked.rn = 1

    ) AS mm

        ON TRIM(CAST(g.material AS CHAR))
         = TRIM(CAST(mm.cod_sap AS CHAR))

    SET
        g.model_simplified =
            CASE
                WHEN NULLIF(TRIM(g.material), '') IS NULL
                    THEN 'UNKNOWN'

                WHEN mm.cod_sap IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(mm.model_simplified), ''),
                    'UNKNOWN'
                )
            END

    WHERE NOT (
        g.model_simplified <=>
        CASE
            WHEN NULLIF(TRIM(g.material), '') IS NULL
                THEN 'UNKNOWN'

            WHEN mm.cod_sap IS NULL
                THEN 'UNKNOWN'

            ELSE COALESCE(
                NULLIF(TRIM(mm.model_simplified), ''),
                'UNKNOWN'
            )
        END
    );


    SET v_rows_updated = ROW_COUNT();


    /*
    ============================================================
    5. FINALIZA EXECUÇÃO
    ============================================================
    */

    SET v_finished_at = NOW(6);


    /*
    ============================================================
    6. LOG DE SUCESSO
    ============================================================
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
        'sp_gold_z17_demo_enrich_model',
        'material_master',
        'gold_zsdbil17_demo_history',
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
        TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
    );


    COMMIT;


    /*
    ============================================================
    7. RETORNO
    ============================================================
    */

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