DELIMITER $$

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_cfop$$

CREATE PROCEDURE bp_datalake.sp_silver_z17_cfop()
BEGIN

    /*
    ============================================================
    VARIABLES
    ============================================================
    */

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_finished_at DATETIME DEFAULT NULL;

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_selected_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;

    DECLARE v_column_exists INT DEFAULT 0;
    DECLARE v_index_exists INT DEFAULT 0;

    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    ERROR HANDLER
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        SET v_finished_at = NOW();

        IF v_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,

                source_rows = v_source_rows,
                selected_rows = v_selected_rows,
                inserted_rows = 0,
                updated_rows = v_updated_rows,
                rejected_rows = 0,

                error_code = CONCAT(
                    'MYSQL ',
                    v_mysql_errno,
                    ' | SQLSTATE ',
                    v_sqlstate
                ),

                error_message = v_error_message,

                execution_duration_seconds = TIMESTAMPDIFF(
                    SECOND,
                    v_started_at,
                    v_finished_at
                )

            WHERE id_execution = v_execution_id;

        END IF;

        RESIGNAL;

    END;


    SET v_started_at = NOW();


    /*
    ============================================================
    1. ENSURE CFOP_CAR COLUMN
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_column_exists
    FROM information_schema.columns
    WHERE table_schema = 'bp_datalake'
      AND table_name = 'silver_zsdbil17_outbound_movements'
      AND column_name = 'cfop_car';


    IF v_column_exists = 0 THEN

        ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
            ADD COLUMN cfop_car VARCHAR(10) NULL
            AFTER cfop;

    END IF;


    /*
    ============================================================
    2. ENSURE INDEX FOR INCREMENTAL PROCESSING
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_index_exists
    FROM information_schema.statistics
    WHERE table_schema = 'bp_datalake'
      AND table_name = 'silver_zsdbil17_outbound_movements'
      AND index_name = 'idx_silver_z17_cfop_car';


    IF v_index_exists = 0 THEN

        CREATE INDEX idx_silver_z17_cfop_car
            ON bp_datalake.silver_zsdbil17_outbound_movements (
                cfop_car
            );

    END IF;


    /*
    ============================================================
    3. START EXECUTION LOG
    ============================================================
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
        'sp_silver_z17_cfop',
        'silver_zsdbil17_outbound_movements',
        'silver_zsdbil17_outbound_movements',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_execution_id = LAST_INSERT_ID();


    /*
    ============================================================
    4. COUNT ONLY PENDING RECORDS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE cfop_car IS NULL;

    SET v_source_rows = v_selected_rows;


    /*
    ============================================================
    5. CLASSIFY CFOP
    ============================================================

    Rules:

    active CFOP + cfop_car = Yes
        -> YES

    active CFOP + cfop_car = No
        -> NO

    CFOP not found
    inactive CFOP
    invalid/null classification
        -> UNKNOWN

    NULL means:
        not processed yet

    ============================================================
    */

    START TRANSACTION;


    UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

    LEFT JOIN bp_datalake.dim_cfop AS d
        ON TRIM(d.cfop) = TRIM(s.cfop)
       AND d.ativo = 1

    SET
        s.cfop_car =
            CASE

                WHEN UPPER(TRIM(d.cfop_car)) = 'YES'
                THEN 'YES'

                WHEN UPPER(TRIM(d.cfop_car)) = 'NO'
                THEN 'NO'

                ELSE 'UNKNOWN'

            END

    WHERE s.cfop_car IS NULL;


    SET v_updated_rows = ROW_COUNT();


    COMMIT;


    /*
    ============================================================
    6. FINISH EXECUTION LOG
    ============================================================
    */

    SET v_finished_at = NOW();


    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,

        source_rows = v_source_rows,
        selected_rows = v_selected_rows,
        inserted_rows = 0,
        updated_rows = v_updated_rows,
        rejected_rows = 0,

        execution_duration_seconds = TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        )

    WHERE id_execution = v_execution_id;


END$$

DELIMITER ;
