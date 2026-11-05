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

-- ============================================================
-- CAMPANHAS (06 / 07)
-- ============================================================

-- A pipeline deve aplicar as campanhas depois do enriquecimento
-- de modelo, porque a elegibilidade depende do model_simplified.
SELECT
    'pipeline_calls_demo_campaign' AS validation_name,
    CASE
        WHEN ROUTINE_DEFINITION LIKE '%sp_gold_z17_demo_enrich_model%sp_gold_z17_demo_apply_campaign%'
            THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'bp_datalake'
  AND ROUTINE_NAME = 'sp_process_zsdbil17_pipeline';

-- Ciclo com campanha precisa ter as datas calculadas pelos dias
-- gravados da campanha (emissao = dia 0).
SELECT
    'campaign_dates_are_consistent' AS validation_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS validation_status,
    COUNT(*) AS inconsistent_rows
FROM bp_datalake.gold_zsdbil17_demo_history
WHERE event_sequence = 1
  AND campaign_code IS NOT NULL
  AND (
      warning_date <> DATE_ADD(issuance_date, INTERVAL campaign_warning_days DAY)
      OR due_date <> DATE_ADD(issuance_date, INTERVAL campaign_due_days DAY)
  );

-- Ciclo aberto com campanha precisa ter o status coerente com
-- o prazo da campanha.
SELECT
    'campaign_status_is_consistent' AS validation_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS validation_status,
    COUNT(*) AS inconsistent_rows
FROM bp_datalake.gold_zsdbil17_demo_history
WHERE event_sequence = 1
  AND campaign_code IS NOT NULL
  AND demo_status <> 'CLOSED'
  AND demo_status <>
      CASE
          WHEN CURRENT_DATE > due_date THEN 'OVERDUE'
          WHEN CURRENT_DATE >= warning_date THEN 'WARNING'
          ELSE 'OPEN'
      END;

-- Alerta: DEMO emitido dentro da janela de uma campanha ativa
-- mas com modelo UNKNOWN/vazio nao recebe campanha. Deve ser
-- corrigido no cadastro Material Code.
SELECT
    'campaign_window_without_model' AS validation_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END AS validation_status,
    COUNT(*) AS cycles_without_model
FROM bp_datalake.gold_zsdbil17_demo_history AS g
WHERE g.event_sequence = 1
  AND g.event_type = 'DEMO'
  AND COALESCE(NULLIF(TRIM(g.model_simplified), ''), 'UNKNOWN') = 'UNKNOWN'
  AND EXISTS (
      SELECT 1
      FROM bp_datalake.dim_demo_campaign AS c
      WHERE c.active = 1
        AND g.issuance_date >= c.issuance_from
        AND (c.issuance_to IS NULL OR g.issuance_date <= c.issuance_to)
  );

-- Distribuicao informativa dos ciclos por campanha e status.
SELECT
    COALESCE(campaign_code, '<PADRAO>') AS campaign_code,
    demo_status,
    COUNT(*) AS cycles
FROM bp_datalake.gold_zsdbil17_demo_history
WHERE event_sequence = 1
GROUP BY COALESCE(campaign_code, '<PADRAO>'), demo_status
ORDER BY campaign_code, demo_status;
