-- ============================================================
-- GOLD - DEMO HISTORY - DEALER ENRICHMENT
-- ============================================================
-- Objetivo:
-- Enriquecer a gold_zsdbil17_demo_history com informações
-- atuais de grupo e marca do dealer.
--
-- Origem:
-- bronze.mapping_dealer_expansion
--
-- Chave:
-- ship_to_party_code -> sap_code
--
-- Destinos:
-- dealer_group
-- brand_dealer
--
-- Estratégia:
-- Utiliza sempre o mapeamento atual do dealer.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_demo_enrich_dealer;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_gold_z17_demo_enrich_dealer()
BEGIN

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_dealer_match BIGINT DEFAULT 0;
    DECLARE v_rows_updated BIGINT DEFAULT 0;
    DECLARE v_unmatched_rows BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    1. TRATAMENTO DE ERRO
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        SET v_finished_at = NOW(6);

        INSERT INTO bp_datalake.etl_execution_log (
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
            execution_duration_seconds
        )
        VALUES (
            'sp_gold_z17_demo_enrich_dealer',
            'bronze.mapping_dealer_expansion',
            'gold_zsdbil17_demo_history',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_dealer_match,
            0,
            v_rows_updated,
            v_unmatched_rows,
            v_error_code,
            v_error_message,
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000
        );

        COMMIT;

        RESIGNAL;

    END;


    /*
    ============================================================
    2. INÍCIO
    ============================================================
    */

    SET v_started_at = NOW(6);


    /*
    ============================================================
    3. GARANTE COLUNAS DE ENRIQUECIMENTO
    ============================================================

    Atualmente as colunas já fazem parte do contrato da tabela.
    Esta validação mantém a procedure independente caso seja
    executada em ambiente ainda não atualizado.
    ============================================================
    */

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_demo_history'
          AND column_name = 'dealer_group'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_demo_history
            ADD COLUMN dealer_group VARCHAR(100) NULL
            AFTER sold_to_party_name;

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_demo_history'
          AND column_name = 'brand_dealer'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_demo_history
            ADD COLUMN brand_dealer VARCHAR(100) NULL
            AFTER dealer_group;

    END IF;


    START TRANSACTION;


    /*
    ============================================================
    4. TOTAL DE LINHAS DA DEMO HISTORY
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_demo_history;


    /*
    ============================================================
    5. MATCHES DE DEALER
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_dealer_match

    FROM bp_datalake.gold_zsdbil17_demo_history AS g

    WHERE EXISTS (
        SELECT 1

        FROM bronze.mapping_dealer_expansion AS d

        WHERE d.sap_code IS NOT NULL
          AND TRIM(CAST(d.sap_code AS CHAR)) <> ''

          AND LPAD(
                TRIM(CAST(g.ship_to_party_code AS CHAR)),
                10,
                '0'
              )
              =
              LPAD(
                TRIM(CAST(d.sap_code AS CHAR)),
                10,
                '0'
              )
    );


    SET v_unmatched_rows =
        v_source_rows - v_dealer_match;


    /*
    ============================================================
    6. ENRIQUECIMENTO DO DEALER
    ============================================================

    Prioridade:
        1. DN
        2. OLD
        3. Pending
        4. Pátio
        5. Yard
        6. Store
        99. demais
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_demo_history AS g

    LEFT JOIN (

        SELECT
            ranked.sap_code,
            ranked.dealer_group,
            ranked.brand

        FROM (

            SELECT
                d.sap_code,
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

                        COALESCE(TRIM(d.dealer_group), ''),
                        COALESCE(TRIM(d.brand), '')
                ) AS rn

            FROM bronze.mapping_dealer_expansion AS d

            WHERE d.sap_code IS NOT NULL
              AND TRIM(CAST(d.sap_code AS CHAR)) <> ''

        ) AS ranked

        WHERE ranked.rn = 1

    ) AS d

        ON LPAD(
               TRIM(CAST(g.ship_to_party_code AS CHAR)),
               10,
               '0'
           )
           =
           LPAD(
               TRIM(CAST(d.sap_code AS CHAR)),
               10,
               '0'
           )

    SET
        g.dealer_group =
            CASE
                WHEN NULLIF(TRIM(g.ship_to_party_code), '') IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.dealer_group), ''),
                    'UNKNOWN'
                )
            END,

        g.brand_dealer =
            CASE
                WHEN NULLIF(TRIM(g.ship_to_party_code), '') IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.brand), ''),
                    'UNKNOWN'
                )
            END

    WHERE
        NOT (
            g.dealer_group <=>
            CASE
                WHEN NULLIF(TRIM(g.ship_to_party_code), '') IS NULL
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
                WHEN NULLIF(TRIM(g.ship_to_party_code), '') IS NULL
                    THEN 'UNKNOWN'

                WHEN d.sap_code IS NULL
                    THEN 'UNKNOWN'

                ELSE COALESCE(
                    NULLIF(TRIM(d.brand), ''),
                    'UNKNOWN'
                )
            END
        );


    SET v_rows_updated = ROW_COUNT();


    /*
    ============================================================
    7. FINALIZA EXECUÇÃO
    ============================================================
    */

    SET v_finished_at = NOW(6);


    /*
    ============================================================
    8. LOG DE SUCESSO
    ============================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (
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
        execution_duration_seconds
    )
    VALUES (
        'sp_gold_z17_demo_enrich_dealer',
        'bronze.mapping_dealer_expansion',
        'gold_zsdbil17_demo_history',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_dealer_match,
        0,
        v_rows_updated,
        v_unmatched_rows,
        NULL,
        NULL,
        TIMESTAMPDIFF(
            MICROSECOND,
            v_started_at,
            v_finished_at
        ) / 1000000
    );


    /*
    ============================================================
    9. CONFIRMA TRANSAÇÃO
    ============================================================
    */

    COMMIT;


    /*
    ============================================================
    10. RETORNO
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,

        v_source_rows AS source_rows,
        v_dealer_match AS dealer_match_rows,
        v_unmatched_rows AS unmatched_rows,

        v_rows_updated AS dealer_updated_rows,

        (
            v_dealer_match
            + v_unmatched_rows
        ) AS accounted_rows,

        ROUND(
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
            2
        ) AS execution_duration_seconds,

        v_started_at AS started_at,
        v_finished_at AS finished_at;


END$$

DELIMITER ;