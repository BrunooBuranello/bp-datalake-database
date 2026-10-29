-- ============================================================
-- ZSDBIL17 - DEMO HISTORY
-- 05 - VALIDACAO POS-IMPLANTACAO
--
-- OBJETIVO:
-- Confirmar, sem alterar dados, os contratos principais depois
-- da recriacao das procedures do historico DEMO.
--
-- RESULTADO ESPERADO:
-- Todas as consultas de controle retornam PASS.
-- ============================================================

-- A procedure de sincronizacao deve exigir explicitamente VALID
-- para que uma movimentacao posterior encerre o ciclo.
SELECT
    'posterior_requires_valid' AS validation_name,
    CASE
        WHEN ROUTINE_DEFINITION LIKE '%) = ''VALID''%'
            THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'bp_datalake'
  AND ROUTINE_NAME = 'sp_sync_gold_zsdbil17_demo_history';

-- A pipeline principal deve executar o enriquecimento de modelo
-- depois que a sincronizacao criar ou atualizar os eventos DEMO.
SELECT
    'pipeline_calls_demo_model_enrichment' AS validation_name,
    CASE
        WHEN ROUTINE_DEFINITION LIKE '%sp_gold_z17_demo_enrich_model%'
            THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'bp_datalake'
  AND ROUTINE_NAME = 'sp_process_zsdbil17_pipeline';

-- CLOSED precisa conservar closed_at; os demais status nao podem
-- carregar uma data de fechamento do ciclo.
SELECT
    'status_and_closed_at_are_consistent' AS validation_name,
    CASE
        WHEN SUM(
            CASE
                WHEN demo_status = 'CLOSED' AND closed_at IS NULL THEN 1
                WHEN demo_status <> 'CLOSED' AND closed_at IS NOT NULL THEN 1
                ELSE 0
            END
        ) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status,
    SUM(
        CASE
            WHEN demo_status = 'CLOSED' AND closed_at IS NULL THEN 1
            WHEN demo_status <> 'CLOSED' AND closed_at IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS inconsistent_rows
FROM bp_datalake.gold_zsdbil17_demo_history
WHERE event_sequence = 1;

-- Depois da pipeline completa, todo evento deve possuir o modelo
-- mapeado ou o fallback explicito UNKNOWN.
SELECT
    'model_enrichment_completed' AS validation_name,
    CASE
        WHEN SUM(
            CASE
                WHEN NULLIF(TRIM(model_simplified), '') IS NULL THEN 1
                ELSE 0
            END
        ) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status,
    SUM(
        CASE
            WHEN NULLIF(TRIM(model_simplified), '') IS NULL THEN 1
            ELSE 0
        END
    ) AS rows_without_model
FROM bp_datalake.gold_zsdbil17_demo_history;

-- Distribuicao informativa das movimentacoes posteriores. Um
-- status novo deve ser analisado antes de mudar a regra de fechamento.
SELECT
    COALESCE(
        NULLIF(UPPER(TRIM(access_key_status)), ''),
        '<EMPTY>'
    ) AS access_key_status,
    event_type,
    COUNT(*) AS total_rows
FROM bp_datalake.gold_zsdbil17_demo_history
WHERE event_sequence > 1
GROUP BY
    COALESCE(
        NULLIF(UPPER(TRIM(access_key_status)), ''),
        '<EMPTY>'
    ),
    event_type
ORDER BY access_key_status, event_type;
