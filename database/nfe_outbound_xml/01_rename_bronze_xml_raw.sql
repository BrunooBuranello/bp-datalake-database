-- ============================================================
-- NF-e DE SAÍDA (XML)
-- 01 - RENOMEAR bronze_xml_raw PARA bronze_nfe_outbound_xml
-- ============================================================
-- Objetivo:
-- Dar à tabela um nome que diga o que ela guarda: os campos
-- LIDOS dos XMLs de NF-e de saída (emitidas pela BYD). O nome
-- antigo "xml_raw" dava a entender que o XML bruto ficava
-- guardado, o que nunca aconteceu. O novo nome forma par com
-- bronze_nfe_return_xml (XMLs de devolução).
--
-- O que faz:
-- 1. RENAME TABLE (instantâneo no MySQL: não copia dados);
-- 2. cria a VIEW bronze_xml_raw apontando para a tabela nova,
--    para que consultas antigas (Power BI, planilhas, SQL
--    manual) continuem funcionando durante a transição;
-- 3. atualiza o COMMENT da tabela.
--
-- Cuidados:
-- - Idempotente: pode rodar mais de uma vez.
-- - Rodar ANTES do deploy do app (branch
--   feat/nfe-outbound-xml-load), que já lê o nome novo.
-- - A VIEW é só leitura; nenhuma carga deve gravar nela.
--   Remover a VIEW quando ninguém mais usar o nome antigo
--   (ADR-001 do app xml_reader).
--
-- Rollback:
--   DROP VIEW bp_datalake.bronze_xml_raw;
--   RENAME TABLE bp_datalake.bronze_nfe_outbound_xml
--       TO bp_datalake.bronze_xml_raw;
-- ============================================================


-- ------------------------------------------------------------
-- 1. RENAME (só se a tabela antiga ainda existir como tabela)
-- ------------------------------------------------------------

DROP PROCEDURE IF EXISTS bp_datalake.tmp_rename_bronze_xml_raw;

DELIMITER $$

CREATE PROCEDURE bp_datalake.tmp_rename_bronze_xml_raw()
BEGIN

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'bronze_xml_raw'
          AND table_type = 'BASE TABLE'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'bronze_nfe_outbound_xml'
    ) THEN
        RENAME TABLE bp_datalake.bronze_xml_raw
            TO bp_datalake.bronze_nfe_outbound_xml;
    END IF;

END$$

DELIMITER ;

CALL bp_datalake.tmp_rename_bronze_xml_raw();

DROP PROCEDURE IF EXISTS bp_datalake.tmp_rename_bronze_xml_raw;


-- ------------------------------------------------------------
-- 2. VIEW DE COMPATIBILIDADE COM O NOME ANTIGO
-- ------------------------------------------------------------
-- Falha de propósito se bronze_xml_raw ainda for uma tabela
-- (o passo 1 não rodou): melhor parar do que esconder o erro.

CREATE OR REPLACE VIEW bp_datalake.bronze_xml_raw AS
SELECT *
FROM bp_datalake.bronze_nfe_outbound_xml;


-- ------------------------------------------------------------
-- 3. COMMENT DA TABELA
-- ------------------------------------------------------------

ALTER TABLE bp_datalake.bronze_nfe_outbound_xml
    COMMENT = 'Campos lidos dos XMLs de NF-e de saida (uma linha por chave de acesso). Carga automatica apos o download_daily_xml.';
