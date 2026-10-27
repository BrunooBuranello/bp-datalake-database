
DELIMITER $$

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_enrich$$

CREATE PROCEDURE bp_datalake.sp_gold_z17_enrich()
BEGIN

    /*
    ============================================================
    ZSDBIL17 - GOLD ENRICHMENT
    ============================================================

    Responsabilidades:
    1. Enriquecimento de dealer pelo CRM
    2. Fallback de dealer pela dim_plant (BYD Internal)
    3. Enriquecimento de condição de pagamento
    4. Enriquecimento de plant
    5. Identificação da origem do chassi

    Regras:
    - Não altera a estrutura da Gold.
    - Não modifica os registros legacy no enriquecimento
      de dealer.
    - Não realiza deduplicação de chassis.
    - Não define sales type ou division.
    - O CRM possui prioridade sobre o fallback interno.

    ============================================================
    */

    -- ========================================================
    -- VARIÁVEIS DE CONTROLE
    -- ========================================================

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


    -- ========================================================
    -- TRATAMENTO DE ERROS
    -- ========================================================

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;


    SET v_started_at = NOW();

    START TRANSACTION;


    -- ========================================================
    -- 1. TOTAL DE REGISTROS DA GOLD
    -- ========================================================

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento;


    /*
    ============================================================
    2. ENRIQUECIMENTO DE DEALER
    ============================================================

    Fonte principal:
        bronze.mapping_dealer_expansion

    Relacionamento:
        gold.ship_to_party_code = mapping.sap_code

    Prioridade de status:
        1. DN
        2. OLD
        3. Pending
        4. Pátio
        5. Yard
        6. Store
        99. Demais status

    Fallback:
        bp_datalake.dim_plant

    Relacionamento do fallback:
        gold.ship_to_party_cnpj = dim_plant.branch_cnpj

    Valor retornado:
        dim_plant.dealer_fallback

    Categorias permitidas:
        Asset
        Asset - Insurance
        Asset Sale

    Destinos:
        store_name_crm
        dealer_group
        brand_dealer

    Escopo:
        record_source = 'ZSDBIL17_CURRENT'

    ============================================================
    */


    -- ========================================================
    -- 2.1 CONTAGEM DE MATCHES NO CRM
    -- ========================================================

    SELECT COUNT(*)
    INTO v_dealer_match
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    WHERE g.record_source = 'ZSDBIL17_CURRENT'
      AND EXISTS (
          SELECT 1
          FROM bronze.mapping_dealer_expansion AS d
          WHERE d.sap_code IS NOT NULL
            AND TRIM(CAST(d.sap_code AS CHAR)) <> ''
            AND LPAD(
                    TRIM(CAST(g.ship_to_party_code AS CHAR)),
                    10, '0'
                ) =
                LPAD(
                    TRIM(CAST(d.sap_code AS CHAR)),
                    10, '0'
                )
      );


    -- ========================================================
    -- 2.2 ENRIQUECIMENTO DO DEALER
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    -- --------------------------------------------------------
    -- MAPEAMENTO PRINCIPAL DO CRM
    -- --------------------------------------------------------

    LEFT JOIN (

        SELECT
            ranked.sap_code,
            ranked.store_name_crm,
            ranked.store_name,
            ranked.dealer_group,
            ranked.brand,
            ranked.status

        FROM (

            SELECT
                d.sap_code,
                d.store_name_crm,
                d.store_name,
                d.dealer_group,
                d.brand,
                d.status,

                ROW_NUMBER() OVER (
                    PARTITION BY d.sap_code
                    ORDER BY

                        CASE TRIM(d.status)
                            WHEN 'DN' THEN 1
                            WHEN 'OLD' THEN 2
                            WHEN 'Pending' THEN 3
                            WHEN 'Pátio' THEN 4
                            WHEN 'Yard' THEN 5
                            WHEN 'Store' THEN 6
                            ELSE 99
                        END,

                        -- Desempate determinístico
                        COALESCE(TRIM(d.store_name_crm), ''),
                        COALESCE(TRIM(d.store_name), ''),
                        COALESCE(TRIM(d.dealer_group), '')

                ) AS rn

            FROM bronze.mapping_dealer_expansion AS d

            WHERE d.sap_code IS NOT NULL
              AND TRIM(CAST(d.sap_code AS CHAR)) <> ''

        ) AS ranked

        WHERE ranked.rn = 1

    ) AS d

        ON LPAD(
            TRIM(CAST(g.ship_to_party_code AS CHAR)),
            10, '0'
        ) =
        LPAD(
            TRIM(CAST(d.sap_code AS CHAR)),
            10, '0'
        )


    -- --------------------------------------------------------
    -- FALLBACK PARA FATURAMENTO INTERNO BYD
    -- --------------------------------------------------------
    /*
    A dimensão define o valor BYD Internal.

    A consulta:
    - Normaliza o CNPJ para 14 dígitos.
    - Ignora valores nulos, vazios ou '-'.
    - Evita múltiplos registros por CNPJ.
    - Ignora CNPJs com classificações divergentes.

    O fallback somente será utilizado quando não houver
    correspondência no mapeamento principal do CRM.
    */

    LEFT JOIN (

        SELECT
            REGEXP_REPLACE(
                CAST(branch_cnpj AS CHAR),
                '[^0-9]', ''
            ) AS cnpj_normalizado,

            MAX(TRIM(dealer_fallback)) AS dealer_fallback

        FROM bp_datalake.dim_plant

        WHERE CHAR_LENGTH(
            REGEXP_REPLACE(
                CAST(branch_cnpj AS CHAR),
                '[^0-9]', ''
            )
        ) = 14

          AND NULLIF(
              NULLIF(TRIM(dealer_fallback), ''),
              '-'
          ) IS NOT NULL

        GROUP BY
            REGEXP_REPLACE(
                CAST(branch_cnpj AS CHAR),
                '[^0-9]', ''
            )

        HAVING COUNT(DISTINCT TRIM(dealer_fallback)) = 1

    ) AS p

        ON BINARY p.cnpj_normalizado =
           BINARY REGEXP_REPLACE(
               CAST(g.ship_to_party_cnpj AS CHAR),
               '[^0-9]', ''
           )

       AND g.division_description IN (
           'Asset',
           'Asset - Insurance',
           'Asset Sale'
       )


    -- --------------------------------------------------------
    -- ATUALIZAÇÃO DAS TRÊS COLUNAS
    -- --------------------------------------------------------

    SET

        -- STORE NAME CRM
        g.store_name_crm =
            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(
                        NULLIF(TRIM(d.store_name_crm), ''),
                        '-'
                    ),
                    NULLIF(
                        NULLIF(TRIM(d.store_name), ''),
                        '-'
                    ),
                    'UNKNOWN'
                )

            END,


        -- DEALER GROUP
        g.dealer_group =
            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.dealer_group), ''),
                    'UNKNOWN'
                )

            END,


        -- BRAND DEALER
        g.brand_dealer =
            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.brand), ''),
                    'UNKNOWN'
                )

            END


    -- --------------------------------------------------------
    -- ATUALIZAR SOMENTE REGISTROS DIFERENTES
    -- --------------------------------------------------------

    WHERE g.record_source = 'ZSDBIL17_CURRENT'

      AND (

        NOT (
            g.store_name_crm <=>

            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(
                        NULLIF(TRIM(d.store_name_crm), ''),
                        '-'
                    ),
                    NULLIF(
                        NULLIF(TRIM(d.store_name), ''),
                        '-'
                    ),
                    'UNKNOWN'
                )

            END
        )

        OR NOT (
            g.dealer_group <=>

            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.dealer_group), ''),
                    'UNKNOWN'
                )

            END
        )

        OR NOT (
            g.brand_dealer <=>

            CASE

                WHEN d.sap_code IS NULL
                     AND p.dealer_fallback IS NOT NULL
                    THEN p.dealer_fallback

                WHEN NULLIF(
                    TRIM(g.ship_to_party_code), ''
                ) IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.brand), ''),
                    'UNKNOWN'
                )

            END
        )

    );

    SET v_dealer_updated = ROW_COUNT();


    /*
    ============================================================
    3. CONDIÇÃO DE PAGAMENTO
    ============================================================

    Origem:
        bp_datalake.dim_cond_pagamento

    Relacionamento:
        payment_condition = cond_pgto_sap

    Destino:
        payment_condition_description_dim

    ============================================================
    */


    -- ========================================================
    -- 3.1 MATCHES VÁLIDOS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_payment_match
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    WHERE EXISTS (
        SELECT 1
        FROM bp_datalake.dim_cond_pagamento AS d

        WHERE TRIM(g.payment_condition) =
              TRIM(d.cond_pgto_sap)

          AND NULLIF(
              TRIM(d.payment_term_description_bp), ''
          ) IS NOT NULL

          AND TRIM(d.payment_term_description_bp) <> '-'
    );


    -- ========================================================
    -- 3.2 ENRIQUECIMENTO
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_cond_pagamento AS d

        ON TRIM(g.payment_condition) =
           TRIM(d.cond_pgto_sap)

    SET
        g.payment_condition_description_dim =
            CASE

                WHEN NULLIF(
                    TRIM(g.payment_condition), ''
                ) IS NULL
                    THEN NULL

                WHEN TRIM(g.payment_condition) = '-'
                    THEN NULL

                WHEN NULLIF(
                    TRIM(d.payment_term_description_bp), ''
                ) IS NULL
                    THEN NULL

                WHEN TRIM(d.payment_term_description_bp) = '-'
                    THEN NULL

                ELSE TRIM(d.payment_term_description_bp)

            END

    WHERE NOT (

        g.payment_condition_description_dim <=>

        CASE

            WHEN NULLIF(
                TRIM(g.payment_condition), ''
            ) IS NULL
                THEN NULL

            WHEN TRIM(g.payment_condition) = '-'
                THEN NULL

            WHEN NULLIF(
                TRIM(d.payment_term_description_bp), ''
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

    Relacionamento:
        plant_code

    Destino:
        plant_description

    ============================================================
    */


    -- ========================================================
    -- 4.1 MATCHES VÁLIDOS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_plant_match
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    WHERE EXISTS (
        SELECT 1
        FROM bp_datalake.dim_plant AS d

        WHERE TRIM(g.plant_code) =
              TRIM(d.plant_code)

          AND NULLIF(
              TRIM(d.plant_description), ''
          ) IS NOT NULL

          AND TRIM(d.plant_description) <> '-'
    );


    -- ========================================================
    -- 4.2 ENRIQUECIMENTO
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_plant AS d

        ON TRIM(g.plant_code) =
           TRIM(d.plant_code)

    SET
        g.plant_description =
            CASE

                WHEN NULLIF(
                    TRIM(g.plant_code), ''
                ) IS NULL
                    THEN NULL

                WHEN TRIM(g.plant_code) = '-'
                    THEN NULL

                WHEN NULLIF(
                    TRIM(d.plant_description), ''
                ) IS NULL
                    THEN NULL

                WHEN TRIM(d.plant_description) = '-'
                    THEN NULL

                ELSE TRIM(d.plant_description)

            END

    WHERE NOT (

        g.plant_description <=>

        CASE

            WHEN NULLIF(
                TRIM(g.plant_code), ''
            ) IS NULL
                THEN NULL

            WHEN TRIM(g.plant_code) = '-'
                THEN NULL

            WHEN NULLIF(
                TRIM(d.plant_description), ''
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

    Regras:
        Primeiro caractere letra  = Importado
        Primeiro caractere número = Nacional

    Destino:
        origem_chassi

    ============================================================
    */


    -- ========================================================
    -- 5.1 ENRIQUECIMENTO
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

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

        g.origem_chassi <=>

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


    -- ========================================================
    -- 5.2 MÉTRICAS DE ORIGEM
    -- ========================================================

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

    FROM bp_datalake.gold_zsdbil17_faturamento;


    -- ========================================================
    -- 6. FINALIZA TRANSAÇÃO
    -- ========================================================

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
