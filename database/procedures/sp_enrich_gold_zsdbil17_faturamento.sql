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
    3. ENRIQUECIMENTO COM A DIMENSÃO DE DEALER
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
END$$

DELIMITER ;