DELIMITER $$

DROP PROCEDURE IF EXISTS sp_enrich_gold_zsdbil17_faturamento$$

CREATE PROCEDURE sp_enrich_gold_zsdbil17_faturamento()
BEGIN

    DECLARE v_exists INT DEFAULT 0;

    DECLARE v_dealer_updated INT DEFAULT 0;
    DECLARE v_payment_updated INT DEFAULT 0;
    DECLARE v_plant_updated INT DEFAULT 0;
    DECLARE v_origem_updated INT DEFAULT 0;

    DECLARE v_started_at DATETIME;
    DECLARE v_finished_at DATETIME;

    SET v_started_at = NOW();

    /*
    =========================================================
    1. GARANTE A COLUNA STORE_NAME_CRM
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
    2. GARANTE A COLUNA DEALER_GROUP
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
    3. GARANTE PAYMENT_CONDITION_DESCRIPTION_DIM
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
    4. GARANTE PLANT_DESCRIPTION
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
    5. GARANTE ORIGEM_CHASSI
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
    6. ENRIQUECIMENTO DEALER
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN silver.mapping_dealer_expansion_unic AS d
        ON TRIM(g.ship_to_party_code) =
           LPAD(CAST(d.sap_code AS CHAR), 10, '0')
       AND d.status_store = 'Opened Store'

    SET
        g.store_name_crm = NULLIF(TRIM(d.store_name_crm), ''),
        g.dealer_group = NULLIF(TRIM(d.dealer_group), '')

    WHERE NOT (
        g.store_name_crm <=> NULLIF(TRIM(d.store_name_crm), '')
    )
       OR NOT (
        g.dealer_group <=> NULLIF(TRIM(d.dealer_group), '')
    );

    SET v_dealer_updated = ROW_COUNT();

    /*
    =========================================================
    7. ENRIQUECIMENTO CONDIÇÃO DE PAGAMENTO
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_cond_pagamento AS d
        ON TRIM(g.payment_condition) =
           TRIM(d.cond_pgto_sap)

    SET
        g.payment_condition_description_dim =
            NULLIF(TRIM(d.payment_term_description_bp), '')

    WHERE NULLIF(TRIM(g.payment_condition), '') IS NOT NULL
      AND TRIM(g.payment_condition) <> '-'
      AND NULLIF(TRIM(d.payment_term_description_bp), '') IS NOT NULL
      AND TRIM(d.payment_term_description_bp) <> '-'
      AND NOT (
          g.payment_condition_description_dim
          <=>
          NULLIF(TRIM(d.payment_term_description_bp), '')
      );

    SET v_payment_updated = ROW_COUNT();

    /*
    =========================================================
    8. ENRIQUECIMENTO PLANT
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_plant AS d
        ON TRIM(g.plant_code) =
           TRIM(d.plant_code)

    SET
        g.plant_description =
            NULLIF(TRIM(d.plant_description), '')

    WHERE NULLIF(TRIM(g.plant_code), '') IS NOT NULL
      AND TRIM(g.plant_code) <> '-'
      AND NULLIF(TRIM(d.plant_description), '') IS NOT NULL
      AND TRIM(d.plant_description) <> '-'
      AND NOT (
          g.plant_description
          <=>
          NULLIF(TRIM(d.plant_description), '')
      );

    SET v_plant_updated = ROW_COUNT();

    /*
    =========================================================
    9. IDENTIFICA ORIGEM DO CHASSI
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    SET g.origem_chassi =
        CASE
            WHEN LEFT(TRIM(g.chassis_serial_number), 1)
                 REGEXP '^[A-Za-z]$'
                THEN 'Importado'

            WHEN LEFT(TRIM(g.chassis_serial_number), 1)
                 REGEXP '^[0-9]$'
                THEN 'Nacional'

            ELSE NULL
        END

    WHERE NOT (
        g.origem_chassi
        <=>
        CASE
            WHEN LEFT(TRIM(g.chassis_serial_number), 1)
                 REGEXP '^[A-Za-z]$'
                THEN 'Importado'

            WHEN LEFT(TRIM(g.chassis_serial_number), 1)
                 REGEXP '^[0-9]$'
                THEN 'Nacional'

            ELSE NULL
        END
    );

    SET v_origem_updated = ROW_COUNT();

    SET v_finished_at = NOW();

    /*
    =========================================================
    10. RESULTADO DA EXECUÇÃO
    =========================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_started_at AS started_at,
        v_finished_at AS finished_at,
        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        ) AS execution_duration_seconds,
        v_dealer_updated AS dealer_updated_rows,
        v_payment_updated AS payment_updated_rows,
        v_plant_updated AS plant_updated_rows,
        v_origem_updated AS origem_chassi_updated_rows,
        (
            v_dealer_updated
            + v_payment_updated
            + v_plant_updated
            + v_origem_updated
        ) AS total_updated_rows;

END$$

DELIMITER ;