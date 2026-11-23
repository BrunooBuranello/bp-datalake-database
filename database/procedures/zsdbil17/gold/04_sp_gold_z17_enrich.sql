
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
    - Só atua nas linhas que não são Legacy (ADR-050 do
      sap_service): o Legacy 2024/2025 passou a ficar na Gold
      entre as execuções e não recebe estes enriquecimentos,
      como antes.

    Desempenho (23/11/2026, ADR-050):
    - CRM, fallback BYD Internal e condição de pagamento viram
      temporárias pequenas com PRIMARY KEY na chave já
      normalizada. A Gold é lida uma vez e cada linha acha o seu
      par pela chave, em vez de comparar cada linha da Gold com
      cada linha da dimensão aplicando LPAD/TRIM/REGEXP dos dois
      lados (~2 min só no dealer).
    - Do lado da Gold a coluna entra sem CAST: CAST(... AS CHAR)
      usa a collation da conexão que criou a procedure e
      impediria o uso da PRIMARY KEY da temporária (ou daria
      "Illegal mix of collations"). As colunas da Gold já são
      texto na collation das temporárias (utf8mb4_0900_ai_ci).
    - Mesmo resultado de antes: medido em 23/11/2026, nenhuma
      chave do CRM ou da condição de pagamento colide depois de
      normalizada.

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
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_dealer_map;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_plant_fallback;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_payment_map;
        RESIGNAL;
    END;


    SET v_started_at = NOW();

    START TRANSACTION;


    -- ========================================================
    -- 1. TOTAL DE REGISTROS DA GOLD
    -- ========================================================

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento
    WHERE NOT (record_source <=> 'LEGACY_2024_2025');


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
        store_code      (código da loja no CRM, da mesma linha
                         do mapeamento; NULL sem match no CRM e
                         no fallback BYD Internal, que não tem
                         código de loja; incluído em 13/11/2026)
        dealer_group
        brand_dealer

    Escopo:
        record_source = 'ZSDBIL17_CURRENT'

    ============================================================
    */


    -- ========================================================
    -- 2.0 MAPA DO CRM (TEMPORÁRIA COM ÍNDICE)
    -- ========================================================
    /*
    Uma linha por chave do CRM, já no formato da comparação
    (LPAD(TRIM(sap_code), 10, '0')), com PRIMARY KEY.

    Prioridade igual à de antes: status (DN, OLD, Pending,
    Pátio, Yard, Store, demais) e depois loja CRM, loja e grupo.
    A partição passou a ser pela chave normalizada (antes era
    pelo sap_code cru): só faz diferença se dois sap_code
    diferentes virarem a mesma chave, o que não acontece hoje
    (0 casos em 23/11/2026). sap_code entra como último
    desempate para o resultado ser sempre o mesmo.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_dealer_map;

    CREATE TEMPORARY TABLE tmp_z17_dealer_map (
        dealer_key VARCHAR(10)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL,
        sap_code TEXT NULL,
        store_name_crm TEXT NULL,
        store_name TEXT NULL,
        store_code TEXT NULL,
        dealer_group TEXT NULL,
        brand TEXT NULL,
        status TEXT NULL,
        PRIMARY KEY (dealer_key)
    ) ENGINE = InnoDB;

    INSERT INTO tmp_z17_dealer_map (
        dealer_key,
        sap_code,
        store_name_crm,
        store_name,
        store_code,
        dealer_group,
        brand,
        status
    )
    SELECT
        ranked.dealer_key,
        ranked.sap_code,
        ranked.store_name_crm,
        ranked.store_name,
        ranked.store_code,
        ranked.dealer_group,
        ranked.brand,
        ranked.status

    FROM (

        SELECT
            LPAD(
                TRIM(CAST(d.sap_code AS CHAR)),
                10, '0'
            ) AS dealer_key,

            d.sap_code,
            d.store_name_crm,
            d.store_name,
            d.store_code,
            d.dealer_group,
            d.brand,
            d.status,

            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(
                        TRIM(CAST(d.sap_code AS CHAR)),
                        10, '0'
                    )
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
                    COALESCE(TRIM(d.dealer_group), ''),
                    d.sap_code

            ) AS rn

        FROM bronze.mapping_dealer_expansion AS d

        WHERE d.sap_code IS NOT NULL
          AND TRIM(CAST(d.sap_code AS CHAR)) <> ''

    ) AS ranked

    WHERE ranked.rn = 1;


    -- ========================================================
    -- 2.1 CONTAGEM DE MATCHES NO CRM
    -- ========================================================

    SELECT COUNT(*)
    INTO v_dealer_match
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    INNER JOIN tmp_z17_dealer_map AS d
        ON d.dealer_key = LPAD(
            TRIM(g.ship_to_party_code),
            10, '0'
        )
    WHERE g.record_source = 'ZSDBIL17_CURRENT';


    -- ========================================================
    -- 2.1.1 FALLBACK BYD INTERNAL (TEMPORÁRIA COM ÍNDICE)
    -- ========================================================
    /*
    Mesma regra de antes (ver comentário do JOIN abaixo), agora
    calculada uma vez numa temporária com PRIMARY KEY no CNPJ
    normalizado. O CNPJ normalizado só tem dígitos, então a
    comparação pela collation da Gold dá o mesmo resultado que a
    comparação BINARY usada antes.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_plant_fallback;

    CREATE TEMPORARY TABLE tmp_z17_plant_fallback (
        cnpj_normalizado VARCHAR(14)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL,
        dealer_fallback VARCHAR(100)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NULL,
        PRIMARY KEY (cnpj_normalizado)
    ) ENGINE = InnoDB;

    INSERT INTO tmp_z17_plant_fallback (
        cnpj_normalizado,
        dealer_fallback
    )
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

    HAVING COUNT(DISTINCT TRIM(dealer_fallback)) = 1;


    -- ========================================================
    -- 2.2 ENRIQUECIMENTO DO DEALER
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    -- --------------------------------------------------------
    -- MAPEAMENTO PRINCIPAL DO CRM
    -- --------------------------------------------------------

    LEFT JOIN tmp_z17_dealer_map AS d

        ON d.dealer_key = LPAD(
            TRIM(g.ship_to_party_code),
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

    LEFT JOIN tmp_z17_plant_fallback AS p

        ON p.cnpj_normalizado = REGEXP_REPLACE(
               g.ship_to_party_cnpj,
               '[^0-9]', ''
           )

       AND g.division_description IN (
           'Asset',
           'Asset - Insurance',
           'Asset Sale'
       )


    -- --------------------------------------------------------
    -- ATUALIZAÇÃO DAS QUATRO COLUNAS
    -- --------------------------------------------------------

    SET

        -- STORE CODE
        -- Mesma linha do CRM escolhida para o store_name_crm
        -- (ranked.rn = 1). Sem match (d.sap_code NULL) fica NULL:
        -- o fallback BYD Internal não tem código de loja.
        g.store_code =
            LEFT(
                NULLIF(NULLIF(TRIM(d.store_code), ''), '-'),
                20
            ),

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
            g.store_code <=>
            LEFT(
                NULLIF(NULLIF(TRIM(d.store_code), ''), '-'),
                20
            )
        )

        OR NOT (
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

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_dealer_map;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_plant_fallback;


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
    -- 3.0 MAPA DA CONDIÇÃO DE PAGAMENTO (TEMPORÁRIA COM ÍNDICE)
    -- ========================================================
    /*
    A dimensão com a chave já sem espaços e PRIMARY KEY. Não há
    duas linhas com a mesma chave depois do TRIM (0 casos em
    23/11/2026); se aparecer, a carga falha na PRIMARY KEY em vez
    de escolher uma das linhas em silêncio.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_payment_map;

    CREATE TEMPORARY TABLE tmp_z17_payment_map (
        cond_pgto_sap VARCHAR(50)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL,
        payment_term_description_bp TEXT NULL,
        PRIMARY KEY (cond_pgto_sap)
    ) ENGINE = InnoDB;

    INSERT INTO tmp_z17_payment_map (
        cond_pgto_sap,
        payment_term_description_bp
    )
    SELECT
        TRIM(d.cond_pgto_sap),
        d.payment_term_description_bp
    FROM bp_datalake.dim_cond_pagamento AS d
    WHERE d.cond_pgto_sap IS NOT NULL;


    -- ========================================================
    -- 3.1 MATCHES VÁLIDOS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_payment_match
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    INNER JOIN tmp_z17_payment_map AS d
        ON d.cond_pgto_sap = TRIM(g.payment_condition)
    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')

      AND NULLIF(
          TRIM(d.payment_term_description_bp), ''
      ) IS NOT NULL

      AND TRIM(d.payment_term_description_bp) <> '-';


    -- ========================================================
    -- 3.2 ENRIQUECIMENTO
    -- ========================================================

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN tmp_z17_payment_map AS d

        ON d.cond_pgto_sap = TRIM(g.payment_condition)

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

    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')
    -- Legacy fora (ADR-050): até 23/11/2026 o Legacy só entrava
    -- na Gold depois desta procedure; agora ele fica na tabela.
    -- O filtro mantém o resultado de antes. <=> trata NULL.

      AND NOT (

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

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_payment_map;


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
    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')
      AND EXISTS (
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

    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')
    -- Legacy fora (ADR-050): até 23/11/2026 o Legacy só entrava
    -- na Gold depois desta procedure; agora ele fica na tabela.
    -- O filtro mantém o resultado de antes. <=> trata NULL.

      AND NOT (

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

    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')
    -- Legacy fora (ADR-050): até 23/11/2026 o Legacy só entrava
    -- na Gold depois desta procedure; agora ele fica na tabela.
    -- O filtro mantém o resultado de antes. <=> trata NULL.

      AND NOT (

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

    FROM bp_datalake.gold_zsdbil17_faturamento
    WHERE NOT (record_source <=> 'LEGACY_2024_2025');


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
