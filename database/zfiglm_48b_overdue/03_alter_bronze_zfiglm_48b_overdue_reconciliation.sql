-- ============================================================
-- MIGRAÇÃO ÚNICA: bronze_zfiglm_48b_overdue  APPEND -> reconciliação
-- (ADR-036 do sap_service, 18/11/2026)
--
-- POR QUÊ:
-- Até aqui cada execução de hora em hora gravava a foto inteira (APPEND),
-- repetindo os mesmos documentos dezenas de vezes por dia. A partir do
-- ADR-036 a Bronze guarda UM conjunto de linhas por documento (nível item)
-- e a procedure sp_stg_reconcile_zfiglm_48b_bronze mantém
-- first_seen_at / last_seen_at / source_status, igual à Z17.
--
-- O QUE ESTE SCRIPT FAZ (nesta ordem):
--   1. Backup integral em bronze_zfiglm_48b_overdue_bkp_20261118
--      (falha se o backup já existir: nunca sobrescreve).
--   2. Adiciona as colunas de controle e os índices novos.
--   3. Calcula o reconciliation_hash das linhas existentes.
--   4. Mantém, para cada hash, só as linhas da ÚLTIMA execução em que ele
--      apareceu (os itens daquela foto); apaga as cópias das execuções
--      anteriores.
--   5. Preenche first_seen_at / last_seen_at a partir do dt_carga
--      histórico e o source_status (ACTIVE / CANCELLED / MISSING).
--
-- PRÉ-REQUISITOS:
-- - Orquestrador desligado e ninguém rodando a ZFIGLM_48B.
-- - Conferir o processlist antes (ALTER pede trava de metadados).
--
-- ROLLBACK:
--   DROP TABLE bp_datalake.bronze_zfiglm_48b_overdue;
--   RENAME TABLE bp_datalake.bronze_zfiglm_48b_overdue_bkp_20261118
--             TO bp_datalake.bronze_zfiglm_48b_overdue;
-- (e voltar o app para o método append do ADR-034).
-- ============================================================


-- ------------------------------------------------------------
-- 1. BACKUP
-- ------------------------------------------------------------
CREATE TABLE bp_datalake.bronze_zfiglm_48b_overdue_bkp_20261118
    LIKE bp_datalake.bronze_zfiglm_48b_overdue;

INSERT INTO bp_datalake.bronze_zfiglm_48b_overdue_bkp_20261118
SELECT * FROM bp_datalake.bronze_zfiglm_48b_overdue;


-- ------------------------------------------------------------
-- 2. COLUNAS DE CONTROLE + ÍNDICES
-- ------------------------------------------------------------
ALTER TABLE bp_datalake.bronze_zfiglm_48b_overdue

    -- MD5 de numero_de_documento_do_sap + empresa + numero_da_nf +
    -- data_do_faturamento. Identifica o DOCUMENTO, não a linha: uma NF
    -- com 50 itens tem 50 linhas e 1 hash.
    ADD COLUMN reconciliation_hash BINARY(16) NULL,

    -- ACTIVE    = presente no último snapshot que cobriu a data da NF.
    -- CANCELLED = coluna "cancelado" preenchida (documento de estorno).
    -- MISSING   = sumiu do relatório numa execução que cobria a data.
    ADD COLUMN source_status VARCHAR(10) NULL,

    -- Primeira e última vez em que o documento apareceu no relatório.
    ADD COLUMN first_seen_at DATETIME NULL,
    ADD COLUMN last_seen_at DATETIME NULL,

    -- Quando o documento sumiu do relatório (NULL se presente).
    ADD COLUMN missing_since DATETIME NULL,

    ADD INDEX idx_bronze_zfiglm_48b_overdue_hash (reconciliation_hash),

    -- Ligação do fiscal (ADR-036): Key reference + NF + data.
    ADD INDEX idx_bronze_zfiglm_48b_overdue_key_reference (key_reference(20)),
    ADD INDEX idx_bronze_zfiglm_48b_overdue_data_do_faturamento (data_do_faturamento(10)),

    -- Usado pela procedure para achar o documento quando o hash muda
    -- (ex.: NF preenchida depois).
    ADD INDEX idx_bronze_zfiglm_48b_overdue_document_key (
        numero_de_documento_do_sap(20),
        empresa(10)
    ),

    ADD INDEX idx_bronze_zfiglm_48b_overdue_source_status (source_status),

    COMMENT = 'ZFIGLM_48B Overdue (SAP), um conjunto de itens por documento, reconciliado pela sp_stg_reconcile_zfiglm_48b_bronze (ADR-036)';


START TRANSACTION;

-- ------------------------------------------------------------
-- 3. HASH DAS LINHAS EXISTENTES (mesma fórmula da procedure)
-- ------------------------------------------------------------
UPDATE bp_datalake.bronze_zfiglm_48b_overdue
SET reconciliation_hash = UNHEX(MD5(CONCAT_WS(
    '|',
    TRIM(numero_de_documento_do_sap),
    TRIM(empresa),
    TRIM(COALESCE(numero_da_nf, '')),
    TRIM(data_do_faturamento)
)));


-- ------------------------------------------------------------
-- 4. MANTER SÓ A ÚLTIMA FOTO DE CADA DOCUMENTO
-- ------------------------------------------------------------

-- Primeira/última aparição de cada hash (dt_carga é TEXT AAAA-MM-DD HH:MM:SS).
DROP TEMPORARY TABLE IF EXISTS tmp_48b_hash_seen;
CREATE TEMPORARY TABLE tmp_48b_hash_seen (
    reconciliation_hash BINARY(16) NOT NULL,
    first_seen_at DATETIME NOT NULL,
    last_seen_at DATETIME NOT NULL,
    PRIMARY KEY (reconciliation_hash)
);

INSERT INTO tmp_48b_hash_seen
SELECT
    reconciliation_hash,
    MIN(CAST(dt_carga AS DATETIME)),
    MAX(CAST(dt_carga AS DATETIME))
FROM bp_datalake.bronze_zfiglm_48b_overdue
GROUP BY reconciliation_hash;

-- Execução que gerou a última aparição de cada hash.
DROP TEMPORARY TABLE IF EXISTS tmp_48b_keep;
CREATE TEMPORARY TABLE tmp_48b_keep (
    reconciliation_hash BINARY(16) NOT NULL,
    id_execucao VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    PRIMARY KEY (reconciliation_hash, id_execucao)
);

INSERT INTO tmp_48b_keep
SELECT DISTINCT
    b.reconciliation_hash,
    b.id_execucao
FROM bp_datalake.bronze_zfiglm_48b_overdue b
INNER JOIN tmp_48b_hash_seen s
    ON s.reconciliation_hash = b.reconciliation_hash
   AND CAST(b.dt_carga AS DATETIME) = s.last_seen_at;

-- Apaga as cópias das execuções anteriores (o backup do passo 1 guarda tudo).
DELETE b
FROM bp_datalake.bronze_zfiglm_48b_overdue b
LEFT JOIN tmp_48b_keep k
    ON k.reconciliation_hash = b.reconciliation_hash
   AND k.id_execucao = b.id_execucao
WHERE k.reconciliation_hash IS NULL;


-- ------------------------------------------------------------
-- 5. FIRST/LAST SEEN + STATUS
-- ------------------------------------------------------------
UPDATE bp_datalake.bronze_zfiglm_48b_overdue b
INNER JOIN tmp_48b_hash_seen s
    ON s.reconciliation_hash = b.reconciliation_hash
SET
    b.first_seen_at = s.first_seen_at,
    b.last_seen_at = s.last_seen_at,
    b.missing_since = NULL,
    b.source_status = CASE
        WHEN TRIM(COALESCE(b.cancelado, '')) <> '' THEN 'CANCELLED'
        ELSE 'ACTIVE'
    END;

-- Execuções que cobriram cada data do faturamento (mesmo escopo de
-- MISSING da procedure: só datas presentes no snapshot).
DROP TEMPORARY TABLE IF EXISTS tmp_48b_runs_by_date;
CREATE TEMPORARY TABLE tmp_48b_runs_by_date (
    data_do_faturamento VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    run_at DATETIME NOT NULL,
    PRIMARY KEY (data_do_faturamento, run_at)
);

INSERT INTO tmp_48b_runs_by_date
SELECT DISTINCT
    LEFT(TRIM(data_do_faturamento), 10),
    CAST(dt_carga AS DATETIME)
FROM bp_datalake.bronze_zfiglm_48b_overdue_bkp_20261118;

-- Documento que sumiu numa execução posterior que cobria a sua data
-- vira MISSING, desde a primeira execução em que não apareceu.
-- Calculado numa temporária: o MySQL não deixa o UPDATE ler a própria
-- tabela numa subconsulta (erro 1093).
DROP TEMPORARY TABLE IF EXISTS tmp_48b_missing;
CREATE TEMPORARY TABLE tmp_48b_missing (
    reconciliation_hash BINARY(16) NOT NULL,
    missing_since DATETIME NOT NULL,
    PRIMARY KEY (reconciliation_hash)
);

INSERT INTO tmp_48b_missing
SELECT
    x.reconciliation_hash,
    MIN(r.run_at)
FROM (
    SELECT DISTINCT
        reconciliation_hash,
        LEFT(TRIM(data_do_faturamento), 10) AS data_do_faturamento,
        last_seen_at
    FROM bp_datalake.bronze_zfiglm_48b_overdue
    WHERE source_status = 'ACTIVE'
) x
INNER JOIN tmp_48b_runs_by_date r
    ON r.data_do_faturamento = x.data_do_faturamento
   AND r.run_at > x.last_seen_at
GROUP BY x.reconciliation_hash;

UPDATE bp_datalake.bronze_zfiglm_48b_overdue b
INNER JOIN tmp_48b_missing m
    ON m.reconciliation_hash = b.reconciliation_hash
SET
    b.source_status = 'MISSING',
    b.missing_since = m.missing_since
WHERE b.source_status = 'ACTIVE';

COMMIT;

DROP TEMPORARY TABLE IF EXISTS tmp_48b_hash_seen;
DROP TEMPORARY TABLE IF EXISTS tmp_48b_keep;
DROP TEMPORARY TABLE IF EXISTS tmp_48b_runs_by_date;
DROP TEMPORARY TABLE IF EXISTS tmp_48b_missing;


-- ------------------------------------------------------------
-- CONFERÊNCIA (rodar e guardar o resultado)
-- ------------------------------------------------------------
-- SELECT source_status, COUNT(*) AS linhas,
--        COUNT(DISTINCT reconciliation_hash) AS documentos
-- FROM bp_datalake.bronze_zfiglm_48b_overdue
-- GROUP BY source_status;
--
-- Deve bater com o número de hashes distintos do backup:
-- SELECT COUNT(DISTINCT MD5(CONCAT_WS('|', TRIM(numero_de_documento_do_sap),
--        TRIM(empresa), TRIM(COALESCE(numero_da_nf, '')), TRIM(data_do_faturamento))))
-- FROM bp_datalake.bronze_zfiglm_48b_overdue_bkp_20261118;
