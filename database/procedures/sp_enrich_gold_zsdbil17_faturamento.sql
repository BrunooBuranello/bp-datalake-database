
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_enrich_gold_zsdbil17_faturamento$$

CREATE PROCEDURE sp_enrich_gold_zsdbil17_faturamento()
BEGIN

    DECLARE v_exists INT DEFAULT 0;

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
    3. GARANTE A COLUNA PAYMENT_CONDITION_DESCRIPTION_DIM
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
    4. ENRIQUECIMENTO COM A DIMENSÃO DE DEALER
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento AS g

    INNER JOIN silver.mapping_dealer_expansion_unic AS d
        ON TRIM(g.ship_to_party_code) =
           LPAD(CAST(d.sap_code AS CHAR), 10, '0')
       AND d.status_store = 'Opened Store'

    SET
        g.store_name_crm = d.store_name_crm,
        g.dealer_group   = d.dealer_group;

    /*
    =========================================================
    5. ENRIQUECIMENTO COM A DIMENSÃO DE CONDIÇÃO DE PAGAMENTO
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
      AND TRIM(d.payment_term_description_bp) <> '-';
    /*
    =========================================================
    6. GARANTE A COLUNA PLANT_DESCRIPTION
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
    7. ENRIQUECIMENTO COM A DIMENSÃO DE PLANT
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
      AND TRIM(d.plant_description) <> '-';
    /*
    =========================================================
    8. GARANTE A COLUNA ORIGEM_CHASSI
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
    9. IDENTIFICA ORIGEM DO CHASSI
    =========================================================
    */

    UPDATE gold_zsdbil17_faturamento

    SET origem_chassi =
        CASE
            WHEN LEFT(TRIM(chassis_serial_number), 1) REGEXP '^[A-Za-z]$'
                THEN 'Importado'

            WHEN LEFT(TRIM(chassis_serial_number), 1) REGEXP '^[0-9]$'
                THEN 'Nacional'

            ELSE NULL
        END;
END$$

DELIMITER ;