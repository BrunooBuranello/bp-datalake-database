DELIMITER $$

DROP PROCEDURE IF EXISTS sp_process_zsdbil17_pipeline$$

CREATE PROCEDURE sp_process_zsdbil17_pipeline()
BEGIN
    DECLARE v_pipeline_execution_id BIGINT DEFAULT NULL;
    DECLARE v_started_at DATETIME;
    DECLARE v_error_code INT;
    DECLARE v_error_message TEXT;

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

        IF v_pipeline_execution_id IS NOT NULL THEN

            UPDATE etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = NOW(),
                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        SECOND,
                        v_started_at,
                        NOW()
                    ),
                error_code = v_error_code,
                error_message = v_error_message
            WHERE id_execution = v_pipeline_execution_id;

        END IF;

        RESIGNAL;
    END;

    SET v_started_at = NOW();

    /*
    =========================================================
    1. REGISTRA O INÍCIO DA PIPELINE
    =========================================================
    */

    INSERT INTO etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        created_at
    )
    VALUES (
        'sp_process_zsdbil17_pipeline',
        'bronze_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_pipeline_execution_id = LAST_INSERT_ID();

    /*
    =========================================================
    2. CARREGA BRONZE → SILVER
    =========================================================
    */

    CALL sp_load_silver_zsdbil17_faturamento();

    /*
    =========================================================
    3. CARREGA SILVER → GOLD
    =========================================================
    */

    CALL sp_load_gold_zsdbil17_faturamento();

    /*
    =========================================================
    4. ENRIQUECE A GOLD
    =========================================================
    */

    CALL sp_enrich_gold_zsdbil17_faturamento();

    /*
    =========================================================
    5. FINALIZA O LOG DA PIPELINE
    =========================================================
    */

    UPDATE etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = NOW(),
        execution_duration_seconds =
            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                NOW()
            ),
        error_code = NULL,
        error_message = NULL
    WHERE id_execution = v_pipeline_execution_id;

END$$

DELIMITER ;