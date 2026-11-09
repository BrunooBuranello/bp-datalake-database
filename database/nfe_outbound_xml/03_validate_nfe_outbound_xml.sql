-- ============================================================
-- NF-e DE SAÍDA (XML)
-- 03 - VALIDAÇÃO DEPOIS DO 01 E DO 02 (somente leitura)
-- ============================================================
-- Esperado em 09/11/2026:
-- - total_rows = distinct_keys = 269.196;
-- - empty_keys = 0 e invalid_keys = 0;
-- - removed_rows = 5.497;
-- - view_rows = total_rows (a VIEW antiga lê a tabela nova);
-- - existe o índice uq_bronze_nfe_outbound_xml_chave_de_acesso
--   com NON_UNIQUE = 0.
-- ============================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT chave_de_acesso) AS distinct_keys,
    SUM(chave_de_acesso IS NULL OR TRIM(chave_de_acesso) = '') AS empty_keys,
    SUM(chave_de_acesso NOT REGEXP '^[0-9]{44}$') AS invalid_keys,
    MAX(dt_carga) AS last_load
FROM bp_datalake.bronze_nfe_outbound_xml;

SELECT COUNT(*) AS removed_rows
FROM bp_datalake.bronze_nfe_outbound_xml_removed_20261109;

SELECT COUNT(*) AS view_rows
FROM bp_datalake.bronze_xml_raw;

SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SUB_PART
FROM information_schema.statistics
WHERE table_schema = 'bp_datalake'
  AND table_name = 'bronze_nfe_outbound_xml'
ORDER BY INDEX_NAME;
