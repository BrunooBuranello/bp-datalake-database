DELIMITER $$

DROP PROCEDURE IF EXISTS sp_process_zsdbil17_pipeline$$

CREATE PROCEDURE sp_process_zsdbil17_pipeline()
BEGIN

    /*
    =========================================================
    1. CARREGA BRONZE → SILVER
    =========================================================
    */

    CALL sp_load_silver_zsdbil17_faturamento();


    /*
    =========================================================
    2. CARREGA SILVER → GOLD
    =========================================================
    */

    CALL sp_load_gold_zsdbil17_faturamento();


    /*
    =========================================================
    3. ENRIQUECE A GOLD
    =========================================================
    */

    CALL sp_enrich_gold_zsdbil17_faturamento();

END$$

DELIMITER ;