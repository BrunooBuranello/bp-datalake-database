USE bp_datalake;

DROP PROCEDURE IF EXISTS sp_silver_z17_access_keys;

DELIMITER $$

CREATE PROCEDURE sp_silver_z17_access_keys()
BEGIN

    /*
    ============================================================
    PROCEDURE
        sp_silver_z17_access_keys

    OBJECTIVE
        Classificar tecnicamente a chave de acesso da NF-e
        na camada Silver.

    STATUS
        MISSING
            chave NULL ou vazia

        CANCELLED
            chave = '00'

        INVALID_FORMAT
            chave diferente de 44 caracteres numéricos

        INVALID_CHECK_DIGIT
            chave possui 44 dígitos, porém DV inválido

        VALID
            chave possui 44 dígitos e DV válido

    IMPORTANT
        Nenhum registro é excluído.

        A procedure garante a existência da coluna
        access_key_status.

        A validação do dígito verificador utiliza módulo 11
        sobre os 43 primeiros dígitos da chave.
    ============================================================
    */


    /*
    ============================================================
    VARIABLES
    ============================================================
    */

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME DEFAULT NOW();
    DECLARE v_finished_at DATETIME;

    DECLARE v_column_exists INT DEFAULT 0;
    DECLARE v_column_created INT DEFAULT 0;

    DECLARE v_total_rows BIGINT DEFAULT 0;
    DECLARE v_rows_changed BIGINT DEFAULT 0;

    DECLARE v_missing BIGINT DEFAULT 0;
    DECLARE v_cancelled BIGINT DEFAULT 0;
    DECLARE v_invalid_format BIGINT DEFAULT 0;
    DECLARE v_invalid_check_digit BIGINT DEFAULT 0;
    DECLARE v_valid BIGINT DEFAULT 0;

    DECLARE v_invalid_total BIGINT DEFAULT 0;
    DECLARE v_classified_total BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    ERROR HANDLER
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_weights;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_validation;

        SET v_finished_at = NOW();


        INSERT INTO bp_datalake.etl_execution_log
        (
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
            audit_details,
            execution_duration_seconds
        )
        VALUES
        (
            'sp_silver_z17_access_keys',
            'silver_zsdbil17_outbound_movements',
            'silver_zsdbil17_outbound_movements',
            'FAILED',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_total_rows,
            v_total_rows,
            0,
            v_rows_changed,
            0,
            v_error_code,
            v_error_message,

            JSON_OBJECT(
                'access_key_status_column_created', v_column_created,
                'missing', v_missing,
                'cancelled', v_cancelled,
                'invalid_format', v_invalid_format,
                'invalid_check_digit', v_invalid_check_digit,
                'valid', v_valid,
                'invalid_total', v_invalid_total,
                'classified_total', v_classified_total,
                'rows_changed', v_rows_changed
            ),

            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            )
        );

        /*
        Garante persistência do log de falha após o rollback
        do processamento principal.
        */
        COMMIT;

        SET v_execution_id = LAST_INSERT_ID();

        RESIGNAL;

    END;


    /*
    ============================================================
    ENSURE OUTPUT COLUMN EXISTS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_column_exists

    FROM information_schema.columns

    WHERE table_schema = 'bp_datalake'
      AND table_name = 'silver_zsdbil17_outbound_movements'
      AND column_name = 'access_key_status';


    IF v_column_exists = 0 THEN

        ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
        ADD COLUMN access_key_status VARCHAR(30) NULL
        AFTER chave_de_acesso;

        SET v_column_created = 1;

    END IF;


    /*
    ============================================================
    SOURCE COUNT
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_total_rows

    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    DATA TRANSACTION
    ============================================================
    */

    START TRANSACTION;


    /*
    ============================================================
    NF-e CHECK DIGIT WEIGHTS

    O DV é o 44º dígito.

    Os 43 primeiros dígitos são multiplicados da direita
    para a esquerda pelos pesos:

        2, 3, 4, 5, 6, 7, 8, 9

    repetidamente.

    Portanto, olhando a chave da esquerda para a direita,
    os pesos ficam:

        4, 3, 2, 9, 8, 7, 6, 5...
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_weights;

    CREATE TEMPORARY TABLE tmp_z17_access_key_weights
    (
        digit_position TINYINT NOT NULL PRIMARY KEY,
        digit_weight TINYINT NOT NULL
    );


    INSERT INTO tmp_z17_access_key_weights
    (
        digit_position,
        digit_weight
    )
    VALUES
        (1,4),
        (2,3),
        (3,2),
        (4,9),
        (5,8),
        (6,7),
        (7,6),
        (8,5),
        (9,4),
        (10,3),
        (11,2),
        (12,9),
        (13,8),
        (14,7),
        (15,6),
        (16,5),
        (17,4),
        (18,3),
        (19,2),
        (20,9),
        (21,8),
        (22,7),
        (23,6),
        (24,5),
        (25,4),
        (26,3),
        (27,2),
        (28,9),
        (29,8),
        (30,7),
        (31,6),
        (32,5),
        (33,4),
        (34,3),
        (35,2),
        (36,9),
        (37,8),
        (38,7),
        (39,6),
        (40,5),
        (41,4),
        (42,3),
        (43,2);


    /*
    ============================================================
    CALCULATE CHECK DIGIT

    Calculamos apenas para chaves com exatamente 44 números.

    Cada chave distinta é calculada uma única vez.
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_validation;

    CREATE TEMPORARY TABLE tmp_z17_access_key_validation
    (
        access_key VARCHAR(44) NOT NULL PRIMARY KEY,
        calculated_check_digit TINYINT NOT NULL
    );


    INSERT INTO tmp_z17_access_key_validation
    (
        access_key,
        calculated_check_digit
    )

    SELECT
        k.access_key,

        CASE

            /*
            Módulo 11:

            resto 0 ou 1
                -> DV = 0

            demais restos
                -> DV = 11 - resto
            */

            WHEN MOD(
                SUM(
                    CAST(
                        SUBSTRING(
                            k.access_key,
                            w.digit_position,
                            1
                        )
                        AS UNSIGNED
                    )
                    * w.digit_weight
                ),
                11
            ) IN (0, 1)

            THEN 0

            ELSE
                11 -
                MOD(
                    SUM(
                        CAST(
                            SUBSTRING(
                                k.access_key,
                                w.digit_position,
                                1
                            )
                            AS UNSIGNED
                        )
                        * w.digit_weight
                    ),
                    11
                )

        END AS calculated_check_digit

    FROM
    (
        SELECT DISTINCT
            TRIM(chave_de_acesso) AS access_key

        FROM bp_datalake.silver_zsdbil17_outbound_movements

        WHERE
            TRIM(chave_de_acesso)
            REGEXP '^[0-9]{44}$'

    ) AS k

    CROSS JOIN tmp_z17_access_key_weights AS w

    GROUP BY
        k.access_key;


    /*
    ============================================================
    CLASSIFY ACCESS KEYS
    ============================================================
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

    LEFT JOIN tmp_z17_access_key_validation AS v
        ON v.access_key = TRIM(s.chave_de_acesso)

    SET
        s.access_key_status =
            CASE

                WHEN s.chave_de_acesso IS NULL
                     OR TRIM(s.chave_de_acesso) = ''
                THEN 'MISSING'


                WHEN TRIM(s.chave_de_acesso) = '00'
                THEN 'CANCELLED'


                WHEN TRIM(s.chave_de_acesso)
                     NOT REGEXP '^[0-9]{44}$'
                THEN 'INVALID_FORMAT'


                WHEN v.calculated_check_digit =
                     CAST(
                         RIGHT(
                             TRIM(s.chave_de_acesso),
                             1
                         )
                         AS UNSIGNED
                     )
                THEN 'VALID'


                ELSE 'INVALID_CHECK_DIGIT'

            END


    /*
    Atualiza apenas quando o status calculado for diferente
    do status atualmente gravado.

    <=> é a comparação NULL-safe do MySQL.
    */

    WHERE NOT
    (
        s.access_key_status
        <=>
        CASE

            WHEN s.chave_de_acesso IS NULL
                 OR TRIM(s.chave_de_acesso) = ''
            THEN 'MISSING'


            WHEN TRIM(s.chave_de_acesso) = '00'
            THEN 'CANCELLED'


            WHEN TRIM(s.chave_de_acesso)
                 NOT REGEXP '^[0-9]{44}$'
            THEN 'INVALID_FORMAT'


            WHEN v.calculated_check_digit =
                 CAST(
                     RIGHT(
                         TRIM(s.chave_de_acesso),
                         1
                     )
                     AS UNSIGNED
                 )
            THEN 'VALID'


            ELSE 'INVALID_CHECK_DIGIT'

        END
    );


    /*
    Deve ser capturado imediatamente depois do UPDATE.
    */

    SET v_rows_changed = ROW_COUNT();


    /*
    ============================================================
    METRICS
    ============================================================
    */

    SELECT

        COALESCE(
            SUM(access_key_status = 'MISSING'),
            0
        ),

        COALESCE(
            SUM(access_key_status = 'CANCELLED'),
            0
        ),

        COALESCE(
            SUM(access_key_status = 'INVALID_FORMAT'),
            0
        ),

        COALESCE(
            SUM(access_key_status = 'INVALID_CHECK_DIGIT'),
            0
        ),

        COALESCE(
            SUM(access_key_status = 'VALID'),
            0
        )

    INTO
        v_missing,
        v_cancelled,
        v_invalid_format,
        v_invalid_check_digit,
        v_valid

    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    SET v_invalid_total =
          v_invalid_format
        + v_invalid_check_digit;


    SET v_classified_total =
          v_missing
        + v_cancelled
        + v_invalid_format
        + v_invalid_check_digit
        + v_valid;


    /*
    ============================================================
    SAFETY CHECK

    Toda linha da Silver deve possuir exatamente um status.
    ============================================================
    */

    IF v_classified_total <> v_total_rows THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Access key classification mismatch: not all Silver rows were classified';

    END IF;


    /*
    ============================================================
    SUCCESS LOG
    ============================================================
    */

    SET v_finished_at = NOW();


    INSERT INTO bp_datalake.etl_execution_log
    (
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
        audit_details,
        execution_duration_seconds
    )
    VALUES
    (
        'sp_silver_z17_access_keys',
        'silver_zsdbil17_outbound_movements',
        'silver_zsdbil17_outbound_movements',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_total_rows,
        v_total_rows,
        0,
        v_rows_changed,
        0,
        NULL,
        NULL,

        JSON_OBJECT(
            'access_key_status_column_created', v_column_created,
            'missing', v_missing,
            'cancelled', v_cancelled,
            'invalid_format', v_invalid_format,
            'invalid_check_digit', v_invalid_check_digit,
            'valid', v_valid,
            'invalid_total', v_invalid_total,
            'classified_total', v_classified_total,
            'rows_changed', v_rows_changed
        ),

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        )
    );


    SET v_execution_id = LAST_INSERT_ID();


    COMMIT;


    /*
    ============================================================
    CLEANUP
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_weights;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_access_key_validation;


    /*
    ============================================================
    RETURN
    ============================================================
    */

    SELECT
        v_execution_id AS execution_id,
        'SUCCESS' AS execution_status,

        v_column_created
            AS access_key_status_column_created,

        v_total_rows AS total_rows,
        v_rows_changed AS rows_changed,

        v_valid AS valid,
        v_missing AS missing,
        v_cancelled AS cancelled,

        v_invalid_format AS invalid_format,
        v_invalid_check_digit AS invalid_check_digit,

        v_invalid_total AS invalid_total,
        v_classified_total AS classified_total;

END$$

DELIMITER ;
