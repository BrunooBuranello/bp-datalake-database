DROP PROCEDURE IF EXISTS bp_datalake.sp_process_zsdbil17_pipeline_v2;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_process_zsdbil17_pipeline_v2()
BEGIN

    DECLARE v_pipeline_execution_id BIGINT DEFAULT NULL;
    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    =========================================================
    TRATAMENTO DE ERRO DA PIPELINE
    =========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        SET v_finished_at = NOW(6);

        IF v_pipeline_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,
                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        MICROSECOND,
                        v_started_at,
                        v_finished_at
                    ) / 1000000,
                error_code = v_error_code,
                error_message = v_error_message
            WHERE id_execution = v_pipeline_execution_id;

        END IF;

        RESIGNAL;

    END;


    /*
    =========================================================
    1. INÍCIO
    =========================================================
    */

    SET v_started_at = NOW(6);


    /*
    =========================================================
    2. REGISTRA INÍCIO DA PIPELINE V2
    =========================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        created_at
    )
    VALUES (
        'sp_process_zsdbil17_pipeline_v2',
        'stg_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento_v2',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_pipeline_execution_id = LAST_INSERT_ID();


    /*
    =========================================================
    3. STAGING -> BRONZE
    =========================================================
    */

    CALL bp_datalake.sp_stg_reconcile_zsdbil17_bronze();


    /*
    =========================================================
    4. SILVER - LOAD BASE
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_load_base();


    /*
    =========================================================
    5. SILVER - NORMALIZAÇÃO
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_normalize();


    /*
    =========================================================
    6. SILVER - VALIDAÇÃO DA CHAVE DE ACESSO
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_access_keys();


    /*
    =========================================================
    7. SILVER - CLASSIFICAÇÃO CFOP
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_cfop();


    /*
    =========================================================
    8. GOLD V2 - LOAD BASE
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_load_base();


    /*
    =========================================================
    9. GOLD V2 - TIPO DE VENDA
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_sales_type();


    /*
    =========================================================
    10. GOLD V2 - ENRIQUECIMENTOS
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_enrich();


    /*
    =========================================================
    11. GOLD V2 - DIRECT SALES
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_direct_sales();


    /*
    =========================================================
    12. FINALIZA PIPELINE
    =========================================================
    */

    SET v_finished_at = NOW(6);

    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,
        execution_duration_seconds =
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
        error_code = NULL,
        error_message = NULL
    WHERE id_execution = v_pipeline_execution_id;


    /*
    =========================================================
    13. RETORNO FINAL
    =========================================================
    */

    SELECT
        v_pipeline_execution_id AS pipeline_execution_id,
        'SUCCESS' AS execution_status,
        'gold_zsdbil17_faturamento_v2' AS target_table,
        v_started_at AS started_at,
        v_finished_at AS finished_at,

        ROUND(
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
            2
        ) AS execution_duration_seconds;

END$$

DELIMITER ;
