
-- ============================================================
-- GOLD - MODEL ENRICHMENT
-- ============================================================
-- Objetivo:
-- Atualizar o modelo simplificado dos veículos na Gold.
--
-- Origem:
-- bp_datalake.bronze_vehicle_material_code
--
-- Relacionamento:
-- gold.material -> bronze_vehicle_material_code.cod_sap
--
-- Destino:
-- gold.model_simplified
--
-- Estratégia:
-- Reconsulta todos os materiais da Gold.
-- Atualiza somente quando o modelo encontrado for diferente
-- do atual, incluindo valores NULL ou UNKNOWN.
--
-- Sem correspondência válida, utiliza UNKNOWN.
-- Considera registros atuais e Legacy.
--
-- Desempenho: o Material Code vira uma temporária com
-- PRIMARY KEY no código (ADR-050 do sap_service, 23/11/2026);
-- detalhes na seção 5.
-- ============================================================

DELIMITER $$

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_enrich_model$$

CREATE PROCEDURE bp_datalake.sp_gold_z17_enrich_model()
BEGIN

    -- ========================================================
    -- 1. VARIÁVEIS
    -- ========================================================

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_model_match BIGINT DEFAULT 0;
    DECLARE v_unmatched_rows BIGINT DEFAULT 0;
    DECLARE v_rows_updated BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    -- ========================================================
    -- 2. TRATAMENTO DE ERROS
    -- ========================================================

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_model_map;

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
            'sp_gold_z17_enrich_model',
            'bronze_vehicle_material_code',
            'gold_zsdbil17_faturamento',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_model_match,
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


    SET v_started_at = NOW(6);


    -- ========================================================
    -- 3. GARANTE A COLUNA MODEL_SIMPLIFIED
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'gold_zsdbil17_faturamento'
          AND column_name = 'model_simplified'
    ) THEN

        ALTER TABLE bp_datalake.gold_zsdbil17_faturamento
            ADD COLUMN model_simplified VARCHAR(100) NULL
            AFTER material;

    END IF;


    START TRANSACTION;


    -- ========================================================
    -- 4. TOTAL DE REGISTROS DA GOLD
    -- ========================================================

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento;


    -- ========================================================
    -- 5. MAPA MATERIAL -> MODELO (TEMPORÁRIA COM ÍNDICE)
    -- ========================================================
    /*
    Desempenho (23/11/2026, ADR-050 do sap_service):
    a versão anterior juntava a Gold com uma subconsulta
    ranqueada usando CONVERT(TRIM(CAST(...))) dos dois lados.
    Com função na coluna o MySQL não usa índice e compara cada
    linha da Gold (~435 mil) com cada material (~1 mil):
    3 a 6 minutos por execução.

    Agora o Material Code vira uma temporária pequena, já
    convertida para a collation da Gold e com PRIMARY KEY no
    código. A Gold é lida uma vez e cada linha acha o seu
    material pela chave (g.material já é gravado com TRIM pelo
    load_base e pelo Legacy).

    Mesmo resultado de antes:
    - uma linha por código (cod_sap é UNIQUE na Bronze; o
      ROW_NUMBER mantém a mesma prioridade: modelo preenchido
      primeiro, depois ordem alfabética do modelo);
    - modelo vazio vira NULL aqui e UNKNOWN no UPDATE;
    - comparação case-insensitive (0900_ai_ci), como a
      unicode_ci usada antes.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_model_map;

    CREATE TEMPORARY TABLE tmp_z17_model_map (
        cod_sap VARCHAR(100)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL,
        model_simplified VARCHAR(255)
            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NULL,
        PRIMARY KEY (cod_sap)
    ) ENGINE = InnoDB;

    INSERT INTO tmp_z17_model_map (
        cod_sap,
        model_simplified
    )
    SELECT
        ranked.cod_key,
        ranked.model_simplified

    FROM (

        SELECT
            CONVERT(
                TRIM(CAST(mm.cod_sap AS CHAR))
                USING utf8mb4
            ) COLLATE utf8mb4_0900_ai_ci AS cod_key,

            NULLIF(TRIM(mm.model_simplified), '') AS model_simplified,

            -- Partição pela chave já convertida: garante uma
            -- linha por valor da PRIMARY KEY da temporária.
            ROW_NUMBER() OVER (

                PARTITION BY
                    CONVERT(
                        TRIM(CAST(mm.cod_sap AS CHAR))
                        USING utf8mb4
                    ) COLLATE utf8mb4_0900_ai_ci

                ORDER BY
                    CASE
                        WHEN NULLIF(
                            TRIM(mm.model_simplified), ''
                        ) IS NOT NULL
                            THEN 1
                        ELSE 2
                    END,

                    COALESCE(
                        TRIM(mm.model_simplified), ''
                    )

            ) AS rn

        FROM bp_datalake.bronze_vehicle_material_code AS mm

        WHERE NULLIF(
            TRIM(CAST(mm.cod_sap AS CHAR)), ''
        ) IS NOT NULL

    ) AS ranked

    WHERE ranked.rn = 1;


    -- ========================================================
    -- 6. REGISTROS COM MODELO IDENTIFICADO
    -- ========================================================

    SELECT COUNT(*)
    INTO v_model_match

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    INNER JOIN tmp_z17_model_map AS mm
        ON mm.cod_sap = g.material

    WHERE mm.model_simplified IS NOT NULL;


    SET v_unmatched_rows =
        v_source_rows - v_model_match;


    -- ========================================================
    -- 7. ENRIQUECIMENTO DO MODELO
    -- ========================================================
    /*
    Atualiza a Gold somente quando o valor for diferente
    (inclui NULL -> UNKNOWN). Sem modelo: UNKNOWN.
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN tmp_z17_model_map AS mm
        ON mm.cod_sap = g.material

    SET
        g.model_simplified =
            COALESCE(mm.model_simplified, 'UNKNOWN')

    WHERE NOT (
        g.model_simplified <=> COALESCE(mm.model_simplified, 'UNKNOWN')
    );


    SET v_rows_updated = ROW_COUNT();

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_model_map;


    -- ========================================================
    -- 8. FINALIZAÇÃO
    -- ========================================================

    SET v_finished_at = NOW(6);


    -- ========================================================
    -- 9. LOG DE SUCESSO
    -- ========================================================

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
        'sp_gold_z17_enrich_model',
        'bronze_vehicle_material_code',
        'gold_zsdbil17_faturamento',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_model_match,
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


    -- ========================================================
    -- 10. CONFIRMA TRANSAÇÃO
    -- ========================================================

    COMMIT;


    -- ========================================================
    -- 11. RESULTADO DA EXECUÇÃO
    -- ========================================================

    SELECT
        'SUCCESS' AS execution_status,

        v_source_rows AS source_rows,
        v_model_match AS model_match_rows,
        v_unmatched_rows AS unmatched_rows,
        v_rows_updated AS model_updated_rows,

        v_model_match + v_unmatched_rows AS accounted_rows,

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
    