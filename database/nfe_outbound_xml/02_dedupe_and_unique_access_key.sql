-- ============================================================
-- NF-e DE SAÍDA (XML)
-- 02 - REMOVER DUPLICADAS E CRIAR UNIQUE NA CHAVE DE ACESSO
-- ============================================================
-- Objetivo:
-- Garantir uma linha por NF-e. A chave de acesso (44 dígitos)
-- identifica uma NF-e de forma única no país inteiro, então
-- duas linhas com a mesma chave são sempre a mesma nota lida
-- duas vezes (uploads manuais repetidos), nunca histórico.
-- Isso justifica a exceção à regra "Bronze não tem UNIQUE"
-- (docs/DATABASE_ARCHITECTURE.md, seção 9; ADR-002 do app
-- xml_reader).
--
-- Diagnóstico de 09/11/2026 (antes deste script):
-- - 274.693 linhas, 269.196 chaves distintas;
-- - 5.447 chaves repetidas = 5.494 linhas sobrando, sempre
--   com o mesmo chassi;
-- - 3 linhas totalmente vazias (sem chave, chassi e data),
--   vindas de linhas em branco do Excel.
-- Resultado esperado: 269.196 linhas, uma por chave.
--
-- O que faz:
-- 1. guarda as linhas removidas em
--    bronze_nfe_outbound_xml_removed_20261109 (rollback);
-- 2. remove as vazias e as cópias, mantendo a linha de MENOR
--    id (a carga mais antiga) de cada chave;
-- 3. troca o índice comum da chave por um UNIQUE.
--
-- Por que UNIQUE com prefixo (44) e a coluna continua TEXT:
-- a Bronze usa TEXT por padrão (seção 7). O MySQL aceita
-- UNIQUE com prefixo em TEXT; como toda chave válida tem
-- exatamente 44 caracteres, o prefixo cobre a chave inteira.
-- A carga do app só aceita chaves com 44 dígitos.
--
-- Cuidados:
-- - Rodar DEPOIS do 01 e ANTES do deploy do app.
-- - Idempotente: rodar de novo não remove nada a mais.
-- - Leva poucos segundos (~275 mil linhas), mas rodar fora
--   do horário das cargas.
--
-- Rollback:
--   ALTER TABLE ... DROP INDEX uq_bronze_nfe_outbound_xml_chave_de_acesso,
--       ADD INDEX idx_chave_de_acesso (chave_de_acesso(255));
--   INSERT INTO bp_datalake.bronze_nfe_outbound_xml
--   SELECT * FROM bp_datalake.bronze_nfe_outbound_xml_removed_20261109;
-- ============================================================


-- ------------------------------------------------------------
-- 1. IDS QUE SERÃO REMOVIDOS
-- ------------------------------------------------------------
-- Tabela temporária evita o erro 1093 do MySQL (DELETE que lê
-- a própria tabela) e garante que backup e DELETE usem
-- exatamente o mesmo conjunto de linhas.

DROP TEMPORARY TABLE IF EXISTS tmp_nfe_outbound_xml_remove_ids;

CREATE TEMPORARY TABLE tmp_nfe_outbound_xml_remove_ids (
    id BIGINT NOT NULL PRIMARY KEY
);

-- Linhas vazias (sem chave de acesso).
INSERT INTO tmp_nfe_outbound_xml_remove_ids (id)
SELECT id
FROM bp_datalake.bronze_nfe_outbound_xml
WHERE chave_de_acesso IS NULL
   OR TRIM(chave_de_acesso) = '';

-- Cópias: todas as linhas da chave, menos a de menor id.
INSERT INTO tmp_nfe_outbound_xml_remove_ids (id)
SELECT t.id
FROM bp_datalake.bronze_nfe_outbound_xml AS t
INNER JOIN (
    SELECT chave_de_acesso, MIN(id) AS keep_id
    FROM bp_datalake.bronze_nfe_outbound_xml
    WHERE chave_de_acesso IS NOT NULL
      AND TRIM(chave_de_acesso) <> ''
    GROUP BY chave_de_acesso
    HAVING COUNT(*) > 1
) AS d
    ON d.chave_de_acesso = t.chave_de_acesso
   AND t.id <> d.keep_id;

-- Conferência antes de apagar (esperado em 09/11: 5.497).
SELECT COUNT(*) AS rows_to_remove
FROM tmp_nfe_outbound_xml_remove_ids;


-- ------------------------------------------------------------
-- 2. BACKUP + DELETE NA MESMA TRANSAÇÃO
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_nfe_outbound_xml_removed_20261109
    LIKE bp_datalake.bronze_nfe_outbound_xml;

START TRANSACTION;

INSERT INTO bp_datalake.bronze_nfe_outbound_xml_removed_20261109
SELECT t.*
FROM bp_datalake.bronze_nfe_outbound_xml AS t
WHERE t.id IN (SELECT id FROM tmp_nfe_outbound_xml_remove_ids)
  AND NOT EXISTS (
      SELECT 1
      FROM bp_datalake.bronze_nfe_outbound_xml_removed_20261109 AS b
      WHERE b.id = t.id
  );

DELETE FROM bp_datalake.bronze_nfe_outbound_xml
WHERE id IN (SELECT id FROM tmp_nfe_outbound_xml_remove_ids);

COMMIT;

DROP TEMPORARY TABLE IF EXISTS tmp_nfe_outbound_xml_remove_ids;


-- ------------------------------------------------------------
-- 3. ÍNDICE COMUM → UNIQUE
-- ------------------------------------------------------------

DROP PROCEDURE IF EXISTS bp_datalake.tmp_unique_nfe_outbound_xml_key;

DELIMITER $$

CREATE PROCEDURE bp_datalake.tmp_unique_nfe_outbound_xml_key()
BEGIN

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'bronze_nfe_outbound_xml'
          AND index_name = 'uq_bronze_nfe_outbound_xml_chave_de_acesso'
    ) THEN
        ALTER TABLE bp_datalake.bronze_nfe_outbound_xml
            ADD UNIQUE INDEX uq_bronze_nfe_outbound_xml_chave_de_acesso
                (chave_de_acesso(44));
    END IF;

    -- O índice comum antigo fica redundante com o UNIQUE.
    IF EXISTS (
        SELECT 1 FROM information_schema.statistics
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'bronze_nfe_outbound_xml'
          AND index_name = 'idx_chave_de_acesso'
    ) THEN
        ALTER TABLE bp_datalake.bronze_nfe_outbound_xml
            DROP INDEX idx_chave_de_acesso;
    END IF;

END$$

DELIMITER ;

CALL bp_datalake.tmp_unique_nfe_outbound_xml_key();

DROP PROCEDURE IF EXISTS bp_datalake.tmp_unique_nfe_outbound_xml_key;
