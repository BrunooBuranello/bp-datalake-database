DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_normalize;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_z17_normalize()
BEGIN

    /*
    ============================================================
    VARIABLES
    ============================================================
    */

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME(6) DEFAULT NULL;
    DECLARE v_finished_at DATETIME(6) DEFAULT NULL;

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_selected_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;

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

        SET v_finished_at = NOW(6);

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

                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        MICROSECOND,
                        v_started_at,
                        v_finished_at
                    ) / 1000000

            WHERE id_execution = v_execution_id;

        END IF;

        RESIGNAL;

    END;


    /*
    ============================================================
    1. START
    ============================================================
    */

    SET v_started_at = NOW(6);


    /*
    ============================================================
    2. START EXECUTION LOG
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
        'sp_silver_z17_normalize',
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
    3. SOURCE ROWS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    4. COUNT ROWS THAT REQUIRE NORMALIZATION
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE
        (
            chassis_serial_number IS NOT NULL
            AND (
                chassis_serial_number <> TRIM(chassis_serial_number)
                OR TRIM(chassis_serial_number) = ''
            )
        )
        OR (
            invoice_number IS NOT NULL
            AND (
                invoice_number <> TRIM(invoice_number)
                OR TRIM(invoice_number) = ''
            )
        )
        OR (
            descricao_do_produto IS NOT NULL
            AND (
                descricao_do_produto <> TRIM(descricao_do_produto)
                OR TRIM(descricao_do_produto) = ''
            )
        )
        OR (
            descricao_da_cor IS NOT NULL
            AND (
                descricao_da_cor <> TRIM(descricao_da_cor)
                OR TRIM(descricao_da_cor) = ''
            )
        );


    /*
    ============================================================
    5. NORMALIZATION
    ============================================================

    Regras:

    - remove espaços somente das extremidades;
    - converte string vazia para NULL.

    Não altera:

    - zeros à esquerda;
    - conteúdo interno;
    - códigos;
    - regras de negócio.

    Colunas:

    - chassis_serial_number
    - invoice_number
    - descricao_do_produto
    - descricao_da_cor

    ============================================================
    */

    START TRANSACTION;


    UPDATE bp_datalake.silver_zsdbil17_outbound_movements

    SET
        chassis_serial_number =
            NULLIF(TRIM(chassis_serial_number), ''),

        invoice_number =
            NULLIF(TRIM(invoice_number), ''),

        descricao_do_produto =
            NULLIF(TRIM(descricao_do_produto), ''),

        descricao_da_cor =
            NULLIF(TRIM(descricao_da_cor), '')

    WHERE
        (
            chassis_serial_number IS NOT NULL
            AND (
                chassis_serial_number <> TRIM(chassis_serial_number)
                OR TRIM(chassis_serial_number) = ''
            )
        )
        OR (
            invoice_number IS NOT NULL
            AND (
                invoice_number <> TRIM(invoice_number)
                OR TRIM(invoice_number) = ''
            )
        )
        OR (
            descricao_do_produto IS NOT NULL
            AND (
                descricao_do_produto <> TRIM(descricao_do_produto)
                OR TRIM(descricao_do_produto) = ''
            )
        )
        OR (
            descricao_da_cor IS NOT NULL
            AND (
                descricao_da_cor <> TRIM(descricao_da_cor)
                OR TRIM(descricao_da_cor) = ''
            )
        );


    SET v_updated_rows = ROW_COUNT();


    COMMIT;


    /*
    ============================================================
    6. FINISH EXECUTION LOG
    ============================================================
    */

    SET v_finished_at = NOW(6);


    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,

        source_rows = v_source_rows,
        selected_rows = v_selected_rows,
        inserted_rows = 0,
        updated_rows = v_updated_rows,
        rejected_rows = 0,

        error_code = NULL,
        error_message = NULL,

        execution_duration_seconds =
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000

    WHERE id_execution = v_execution_id;


    /*
    ============================================================
    7. RETURN
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_source_rows AS source_rows,
        v_selected_rows AS selected_rows,
        v_updated_rows AS updated_rows,

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
