DELIMITER $$

DROP PROCEDURE IF EXISTS sp_gold_z17_enrich$$

CREATE PROCEDURE sp_gold_z17_enrich()
BEGIN

    /*
    ============================================================
    ZSDBIL17 - GOLD ENRICHMENT
    ============================================================

    Responsabilidade:
    - Enriquecer informações de dealer
    - Enriquecer condição de pagamento
    - Enriquecer plant
    - Identificar origem do chassi

    Não é responsabilidade desta procedure:
    - Criar ou alterar estrutura da Gold
    - Validar chave de acesso
    - Validar source_status
    - Filtrar CFOP de veículo
    - Deduplicar chassis
    - Definir sales type / division
    ============================================================
    */


    /*
    ============================================================
    VARIÁVEIS
    ============================================================
    */

    DECLARE v_source_rows BIGINT DEFAULT 0;

    DECLARE v_dealer_match BIGINT DEFAULT 0;
    DECLARE v_dealer_updated BIGINT DEFAULT 0;

    DECLARE v_payment_match BIGINT DEFAULT 0;
    DECLARE v_payment_updated BIGINT DEFAULT 0;

    DECLARE v_plant_match BIGINT DEFAULT 0;
    DECLARE v_plant_updated BIGINT DEFAULT 0;

    DECLARE v_origem_identified BIGINT DEFAULT 0;
    DECLARE v_origem_importado BIGINT DEFAULT 0;
    DECLARE v_origem_nacional BIGINT DEFAULT 0;
    DECLARE v_origem_unknown BIGINT DEFAULT 0;
    DECLARE v_origem_updated BIGINT DEFAULT 0;

    DECLARE v_started_at DATETIME;
    DECLARE v_finished_at DATETIME;


    /*
    ============================================================
    TRATAMENTO DE ERRO
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;


    SET v_started_at = NOW();

    START TRANSACTION;


    /*
    ============================================================
    1. TOTAL DE LINHAS DA GOLD
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento_v2;


    /*
    ============================================================
    2. DEALER
    ============================================================

    Origem:
        silver.mapping_dealer_expansion_unic

    Chave:
        ship_to_party_code -> sap_code

    Destinos:
        store_name_crm
        dealer_group
        brand_dealer
    ============================================================
    */


    /*
    ------------------------------------------------------------
    2.1 MATCHES ENCONTRADOS
    ------------------------------------------------------------
    */

    SELECT COUNT(*)
    INTO v_dealer_match

    FROM bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    WHERE EXISTS (

        SELECT 1

        FROM silver.mapping_dealer_expansion_unic AS d

        WHERE TRIM(g.ship_to_party_code) =
              LPAD(CAST(d.sap_code AS CHAR), 10, '0')

    );


    /*
    ------------------------------------------------------------
    2.2 ENRIQUECIMENTO
    ------------------------------------------------------------
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    LEFT JOIN silver.mapping_dealer_expansion_unic AS d
        ON TRIM(g.ship_to_party_code) =
           LPAD(CAST(d.sap_code AS CHAR), 10, '0')

    SET
        g.store_name_crm =
            COALESCE(
                NULLIF(TRIM(d.store_name_crm), ''),
                NULLIF(TRIM(d.store_name), '')
            ),

        g.dealer_group =
            NULLIF(
                TRIM(d.dealer_group),
                ''
            ),

        g.brand_dealer =
            NULLIF(
                TRIM(d.brand),
                ''
            )

    WHERE

        NOT (
            g.store_name_crm
            <=>
            COALESCE(
                NULLIF(TRIM(d.store_name_crm), ''),
                NULLIF(TRIM(d.store_name), '')
            )
        )

        OR NOT (
            g.dealer_group
            <=>
            NULLIF(TRIM(d.dealer_group), '')
        )

        OR NOT (
            g.brand_dealer
            <=>
            NULLIF(TRIM(d.brand), '')
        );


    SET v_dealer_updated = ROW_COUNT();


    /*
    ============================================================
    3. CONDIÇÃO DE PAGAMENTO
    ============================================================

    Origem:
        bp_datalake.dim_cond_pagamento

    Chave:
        payment_condition -> cond_pgto_sap

    Destino:
        payment_condition_description_dim
    ============================================================
    */


    /*
    ------------------------------------------------------------
    3.1 MATCHES VÁLIDOS
    ------------------------------------------------------------
    */

    SELECT COUNT(*)
    INTO v_payment_match

    FROM bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    WHERE EXISTS (

        SELECT 1

        FROM bp_datalake.dim_cond_pagamento AS d

        WHERE TRIM(g.payment_condition) =
              TRIM(d.cond_pgto_sap)

          AND NULLIF(
                  TRIM(d.payment_term_description_bp),
                  ''
              ) IS NOT NULL

          AND TRIM(d.payment_term_description_bp) <> '-'

    );


    /*
    ------------------------------------------------------------
    3.2 ENRIQUECIMENTO
    ------------------------------------------------------------
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    LEFT JOIN bp_datalake.dim_cond_pagamento AS d
        ON TRIM(g.payment_condition) =
           TRIM(d.cond_pgto_sap)

    SET
        g.payment_condition_description_dim =
            CASE

                WHEN NULLIF(
                        TRIM(g.payment_condition),
                        ''
                     ) IS NULL
                    THEN NULL

                WHEN TRIM(g.payment_condition) = '-'
                    THEN NULL

                WHEN NULLIF(
                        TRIM(d.payment_term_description_bp),
                        ''
                     ) IS NULL
                    THEN NULL

                WHEN TRIM(d.payment_term_description_bp) = '-'
                    THEN NULL

                ELSE TRIM(d.payment_term_description_bp)

            END

    WHERE NOT (

        g.payment_condition_description_dim

        <=>

        CASE

            WHEN NULLIF(
                    TRIM(g.payment_condition),
                    ''
                 ) IS NULL
                THEN NULL

            WHEN TRIM(g.payment_condition) = '-'
                THEN NULL

            WHEN NULLIF(
                    TRIM(d.payment_term_description_bp),
                    ''
                 ) IS NULL
                THEN NULL

            WHEN TRIM(d.payment_term_description_bp) = '-'
                THEN NULL

            ELSE TRIM(d.payment_term_description_bp)

        END

    );


    SET v_payment_updated = ROW_COUNT();


    /*
    ============================================================
    4. PLANT
    ============================================================

    Origem:
        bp_datalake.dim_plant

    Chave:
        plant_code

    Destino:
        plant_description
    ============================================================
    */


    /*
    ------------------------------------------------------------
    4.1 MATCHES VÁLIDOS
    ------------------------------------------------------------
    */

    SELECT COUNT(*)
    INTO v_plant_match

    FROM bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    WHERE EXISTS (

        SELECT 1

        FROM bp_datalake.dim_plant AS d

        WHERE TRIM(g.plant_code) =
              TRIM(d.plant_code)

          AND NULLIF(
                  TRIM(d.plant_description),
                  ''
              ) IS NOT NULL

          AND TRIM(d.plant_description) <> '-'

    );


    /*
    ------------------------------------------------------------
    4.2 ENRIQUECIMENTO
    ------------------------------------------------------------
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    LEFT JOIN bp_datalake.dim_plant AS d
        ON TRIM(g.plant_code) =
           TRIM(d.plant_code)

    SET
        g.plant_description =
            CASE

                WHEN NULLIF(
                        TRIM(g.plant_code),
                        ''
                     ) IS NULL
                    THEN NULL

                WHEN TRIM(g.plant_code) = '-'
                    THEN NULL

                WHEN NULLIF(
                        TRIM(d.plant_description),
                        ''
                     ) IS NULL
                    THEN NULL

                WHEN TRIM(d.plant_description) = '-'
                    THEN NULL

                ELSE TRIM(d.plant_description)

            END

    WHERE NOT (

        g.plant_description

        <=>

        CASE

            WHEN NULLIF(
                    TRIM(g.plant_code),
                    ''
                 ) IS NULL
                THEN NULL

            WHEN TRIM(g.plant_code) = '-'
                THEN NULL

            WHEN NULLIF(
                    TRIM(d.plant_description),
                    ''
                 ) IS NULL
                THEN NULL

            WHEN TRIM(d.plant_description) = '-'
                THEN NULL

            ELSE TRIM(d.plant_description)

        END

    );


    SET v_plant_updated = ROW_COUNT();


    /*
    ============================================================
    5. ORIGEM DO CHASSI
    ============================================================

    Regra:
        primeiro caractere letra  -> Importado
        primeiro caractere número -> Nacional

    Destino:
        origem_chassi
    ============================================================
    */


    /*
    ------------------------------------------------------------
    5.1 ENRIQUECIMENTO
    ------------------------------------------------------------
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    SET
        g.origem_chassi =
            CASE

                WHEN TRIM(g.chassis_serial_number)
                     REGEXP '^[A-Za-z]'
                    THEN 'Importado'

                WHEN TRIM(g.chassis_serial_number)
                     REGEXP '^[0-9]'
                    THEN 'Nacional'

                ELSE NULL

            END

    WHERE NOT (

        g.origem_chassi

        <=>

        CASE

            WHEN TRIM(g.chassis_serial_number)
                 REGEXP '^[A-Za-z]'
                THEN 'Importado'

            WHEN TRIM(g.chassis_serial_number)
                 REGEXP '^[0-9]'
                THEN 'Nacional'

            ELSE NULL

        END

    );


    SET v_origem_updated = ROW_COUNT();


    /*
    ------------------------------------------------------------
    5.2 MÉTRICAS DE ORIGEM
    ------------------------------------------------------------
    */

    SELECT
        SUM(origem_chassi IS NOT NULL),

        SUM(origem_chassi = 'Importado'),

        SUM(origem_chassi = 'Nacional'),

        SUM(origem_chassi IS NULL)

    INTO
        v_origem_identified,
        v_origem_importado,
        v_origem_nacional,
        v_origem_unknown

    FROM bp_datalake.gold_zsdbil17_faturamento_v2;


    /*
    ============================================================
    6. FINALIZA TRANSAÇÃO
    ============================================================
    */

    COMMIT;

    SET v_finished_at = NOW();


    /*
    ============================================================
    7. RESULTADO DA EXECUÇÃO
    ============================================================
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

        v_source_rows AS source_rows,

        v_dealer_match AS dealer_match_rows,
        v_dealer_updated AS dealer_updated_rows,

        v_payment_match AS payment_match_rows,
        v_payment_updated AS payment_updated_rows,

        v_plant_match AS plant_match_rows,
        v_plant_updated AS plant_updated_rows,

        v_origem_identified AS origem_identified_rows,
        v_origem_importado AS origem_importado_rows,
        v_origem_nacional AS origem_nacional_rows,
        v_origem_unknown AS origem_unknown_rows,
        v_origem_updated AS origem_updated_rows,

        (
            v_dealer_updated
            + v_payment_updated
            + v_plant_updated
            + v_origem_updated
        ) AS total_update_operations;

END$$

DELIMITER ;
