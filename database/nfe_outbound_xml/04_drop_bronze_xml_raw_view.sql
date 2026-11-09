-- ============================================================
-- NF-e DE SAÍDA (XML)
-- 04 - REMOVER A VIEW DE COMPATIBILIDADE bronze_xml_raw
-- ============================================================
-- Objetivo:
-- Encerrar a transição do script 01. A VIEW bronze_xml_raw só
-- existia para consultas antigas que ainda usassem o nome
-- velho. Em 09/11/2026 o Bruno confirmou que só o app usava
-- esse nome, e o app já lê bronze_nfe_outbound_xml.
--
-- O que faz:
-- 1. DROP VIEW da bronze_xml_raw (a tabela não é tocada);
-- 2. confirma que sobrou só a tabela nova.
--
-- Cuidados:
-- - DROP VIEW nunca apaga tabela: se bronze_xml_raw fosse uma
--   tabela, o MySQL recusaria o comando com erro.
-- - Idempotente: IF EXISTS permite rodar de novo.
-- - Rollback: rodar de novo o passo 2 do script 01
--   (CREATE OR REPLACE VIEW bp_datalake.bronze_xml_raw ...).
-- ============================================================

DROP VIEW IF EXISTS bp_datalake.bronze_xml_raw;

-- Esperado: uma linha só, bronze_nfe_outbound_xml / BASE TABLE.
SELECT TABLE_NAME, TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'bp_datalake'
  AND TABLE_NAME IN ('bronze_xml_raw', 'bronze_nfe_outbound_xml');
