DELIMITER $$

DROP PROCEDURE IF EXISTS sp_enrich_gold_zsdbil17_faturamento$$

CREATE PROCEDURE sp_enrich_gold_zsdbil17_faturamento()
BEGIN

    /*
    =========================================================
    VARIÁVEIS
    =========================================================
    */

    DECLARE v_exists INT DEFAULT 0;

    DECLARE v_dealer_updated INT DEFAULT 0;
    DECLARE v_payment_updated INT DEFAULT 0;
    DECLARE v_plant_updated INT DEFAULT 0;
    DECLARE v_origem_updated INT DEFAULT 0;
    DECLARE v_division_updated INT DEFAULT 0;

    DECLARE v_total_updated INT DEFAULT 0;

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME;
    DECLARE v_finished_at DATETIME;

    DECLARE v_error_code INT;
    DECLARE v_error_message TEXT;


    /*
    =========================================================
    TRATAMENTO DE ERRO
    =========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        SET v_finished_at = NOW();

        IF v_execution_id IS NOT NULL THEN

            UPDATE etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,

                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        SECOND,
                        v_started_at,
                        v_finished_at
                    ),

                source_rows = v_source_rows,
                selected_rows = v_source_rows,
                inserted_rows = 0,

                updated_rows = (
                    v_dealer_updated
                    + v_payment_updated
                    + v_plant_updated
                    + v_origem_updated
                    + v_division_updated
                ),

                rejected_rows = 0,

                error_code = v_error_code,
                error_message = v_error_message

            WHERE id_execution = v_execution_id;

        END IF;

        RESIGNAL;

    END;


    SET v_started_at = NOW();


    /*
    =========================================================
    1. REGISTRA O INÍCIO DA EXECUÇÃO
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
        'sp_enrich_gold_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_execution_id = LAST_INSERT_ID();


    /*
    =========================================================
    2. CONTAGEM DA GOLD
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM gold_zsdbil17_faturamento;


    /*
    =========================================================
    3. GARANTE A COLUNA STORE_NAME_CRM
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'store_name_crm';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN store_name_crm VARCHAR(100);

    END IF;


    /*
    =========================================================
    4. GARANTE A COLUNA DEALER_GROUP
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'dealer_group';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN dealer_group VARCHAR(100);

    END IF;


    /*
    =========================================================
    5. GARANTE PAYMENT_CONDITION_DESCRIPTION_DIM
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'payment_condition_description_dim';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN payment_condition_description_dim VARCHAR(255);

    END IF;


    /*
    =========================================================
    6. GARANTE PLANT_DESCRIPTION
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'plant_description';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN plant_description VARCHAR(100);

    END IF;


    /*
    =========================================================
    7. GARANTE ORIGEM_CHASSI
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'origem_chassi';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN origem_chassi VARCHAR(20);

    END IF;


    /*
    =========================================================
    8. GARANTE DIVISION_DESCRIPTION
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_exists
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'gold_zsdbil17_faturamento'
      AND column_name = 'division_description';

    IF v_exists = 0 THEN

        ALTER TABLE gold_zsdbil17_faturamento
            ADD COLUMN division_description VARCHAR(100)
            AFTER division;

    END IF;


    /*
    =========================================================
    9. ENRIQUECIMENTO DEALER
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN silver.mapping_dealer_expansion_unic AS d
        ON TRIM(g.ship_to_party_code) =
           LPAD(CAST(d.sap_code AS CHAR), 10, '0')

       AND d.status_store = 'Opened Store'

    SET
        g.store_name_crm =
            NULLIF(
                TRIM(d.store_name_crm),
                ''
            ),

        g.dealer_group =
            NULLIF(
                TRIM(d.dealer_group),
                ''
            )

    WHERE
        NOT (
            g.store_name_crm
            <=>
            NULLIF(
                TRIM(d.store_name_crm),
                ''
            )
        )

        OR NOT (
            g.dealer_group
            <=>
            NULLIF(
                TRIM(d.dealer_group),
                ''
            )
        );

    SET v_dealer_updated = ROW_COUNT();


    /*
    =========================================================
    10. ENRIQUECIMENTO CONDIÇÃO DE PAGAMENTO
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_cond_pagamento AS d
        ON TRIM(g.payment_condition) =
           TRIM(d.cond_pgto_sap)

    SET
        g.payment_condition_description_dim =
            NULLIF(
                TRIM(d.payment_term_description_bp),
                ''
            )

    WHERE
        NULLIF(
            TRIM(g.payment_condition),
            ''
        ) IS NOT NULL

        AND TRIM(g.payment_condition) <> '-'

        AND NULLIF(
            TRIM(d.payment_term_description_bp),
            ''
        ) IS NOT NULL

        AND TRIM(d.payment_term_description_bp) <> '-'

        AND NOT (
            g.payment_condition_description_dim
            <=>
            NULLIF(
                TRIM(d.payment_term_description_bp),
                ''
            )
        );

    SET v_payment_updated = ROW_COUNT();


    /*
    =========================================================
    11. ENRIQUECIMENTO PLANT
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_plant AS d
        ON TRIM(g.plant_code) =
           TRIM(d.plant_code)

    SET
        g.plant_description =
            NULLIF(
                TRIM(d.plant_description),
                ''
            )

    WHERE
        NULLIF(
            TRIM(g.plant_code),
            ''
        ) IS NOT NULL

        AND TRIM(g.plant_code) <> '-'

        AND NULLIF(
            TRIM(d.plant_description),
            ''
        ) IS NOT NULL

        AND TRIM(d.plant_description) <> '-'

        AND NOT (
            g.plant_description
            <=>
            NULLIF(
                TRIM(d.plant_description),
                ''
            )
        );

    SET v_plant_updated = ROW_COUNT();


    /*
    =========================================================
    12. IDENTIFICA ORIGEM DO CHASSI
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    SET
        g.origem_chassi =
            CASE

                WHEN LEFT(
                    TRIM(g.chassis_serial_number),
                    1
                ) REGEXP '^[A-Za-z]$'
                    THEN 'Importado'

                WHEN LEFT(
                    TRIM(g.chassis_serial_number),
                    1
                ) REGEXP '^[0-9]$'
                    THEN 'Nacional'

                ELSE NULL

            END

    WHERE NOT (

        g.origem_chassi

        <=>

        CASE

            WHEN LEFT(
                TRIM(g.chassis_serial_number),
                1
            ) REGEXP '^[A-Za-z]$'
                THEN 'Importado'

            WHEN LEFT(
                TRIM(g.chassis_serial_number),
                1
            ) REGEXP '^[0-9]$'
                THEN 'Nacional'

            ELSE NULL

        END

    );

    SET v_origem_updated = ROW_COUNT();


    /*
    =========================================================
    13. ENRIQUECIMENTO DIVISION
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_sales_order_type AS d
        ON TRIM(g.division) =
           TRIM(d.sales_order_type)

    SET
        g.division_description =
            NULLIF(
                TRIM(d.sales_order_type_description),
                ''
            )

    WHERE
        NULLIF(
            TRIM(g.division),
            ''
        ) IS NOT NULL

        AND NULLIF(
            TRIM(d.sales_order_type_description),
            ''
        ) IS NOT NULL

        AND NOT (
            g.division_description
            <=>
            NULLIF(
                TRIM(d.sales_order_type_description),
                ''
            )
        );

    SET v_division_updated = ROW_COUNT();


    /*
    =========================================================
    14. FINALIZA AS MÉTRICAS
    =========================================================
    */

    SET v_total_updated =
          v_dealer_updated
        + v_payment_updated
        + v_plant_updated
        + v_origem_updated
        + v_division_updated;

    SET v_finished_at = NOW();


    /*
    =========================================================
    15. FINALIZA O LOG COM SUCESSO
    =========================================================
    */

    UPDATE etl_execution_log
    SET
        execution_status = 'SUCCESS',

        finished_at = v_finished_at,

        execution_duration_seconds =
            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            ),

        source_rows = v_source_rows,
        selected_rows = v_source_rows,

        inserted_rows = 0,

        updated_rows = v_total_updated,

        rejected_rows = 0,

        error_code = NULL,
        error_message = NULL

    WHERE id_execution = v_execution_id;


    /*
    =========================================================
    16. RESULTADO DA EXECUÇÃO
    =========================================================
    */

    SELECT
        v_execution_id AS id_execution,

        'SUCCESS' AS execution_status,

        v_started_at AS started_at,

        v_finished_at AS finished_at,

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        ) AS execution_duration_seconds,

        v_source_rows AS source_rows,

        v_dealer_updated AS dealer_updated_rows,

        v_payment_updated AS payment_updated_rows,

        v_plant_updated AS plant_updated_rows,

        v_origem_updated AS origem_chassi_updated_rows,

        v_division_updated AS division_updated_rows,

        v_total_updated AS total_updated_rows;


END$$

DELIMITER ;
