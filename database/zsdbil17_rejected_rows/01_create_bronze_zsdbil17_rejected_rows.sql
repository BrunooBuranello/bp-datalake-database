-- ============================================================
-- TABELA: bronze_zsdbil17_rejected_rows
-- CAMADA: Bronze
--
-- ORIGEM:
-- Linhas do CSV da ZSDBIL17 (Z17) rejeitadas pelo contrato do
-- pré-processamento do BYD Sales Operation
-- (sap_service/services/database/csv_preprocessor.py, ADR-012 do
-- sap_service). Arquivo de origem: <Z17_...>_rejected.csv.
--
-- OBJETIVO:
-- Não deixar a linha rejeitada sumir. Ela fica fora da staging e da
-- Bronze da Z17 (formato errado = dado que iria para a coluna errada),
-- mas fica registrada aqui, com a linha bruta e o motivo, para
-- conferência no SAP e reprocessamento (ADR-014 do sap_service).
--
-- ESTRATÉGIA:
-- - APPEND a cada execução da Z17 que tiver rejeição (sem DELETE).
-- - Duplicidades permitidas: a Z17 roda de hora em hora e reextrai o
--   período, então a mesma linha reaparece; distinguir por id_execucao
--   e dt_carga.
-- - Todas as colunas TEXT (padrão Bronze): a linha é justamente a que
--   não segue o formato esperado.
-- - Volume baixo: 3 rejeições em ~1,8 milhão de linhas (set–nov/2026).
--
-- APLICAR ANTES do deploy do app que grava nesta tabela. Sem a tabela,
-- a Z17 continua carregando normalmente e só registra um aviso.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_zsdbil17_rejected_rows (

    -- ========================================================
    -- POSIÇÃO NO ARQUIVO
    -- ========================================================

    -- Número do registro lógico (cabeçalho = 1).
    record_number TEXT NULL,

    -- Linha física do CSV (difere do registro quando há quebra de
    -- linha dentro de um campo entre aspas).
    physical_line TEXT NULL,


    -- ========================================================
    -- DIAGNÓSTICO
    -- ========================================================

    expected_columns TEXT NULL,

    found_columns TEXT NULL,

    -- column_count_mismatch, invalid_issuance_date, invalid_cfop,
    -- invalid_chassis (vários motivos separados por ';').
    reason TEXT NULL,

    -- Linha bruta como lista Python (repr), fiel à origem.
    raw_row TEXT NULL,


    -- ========================================================
    -- AUDITORIA
    -- ========================================================

    dt_carga TEXT NULL,

    -- Arquivo original exportado do SAP (Z17_AAAAMMDD_HHMMSS.csv).
    source_file TEXT NULL,

    -- job_id da execução da Z17 no BYD Sales Operation.
    id_execucao TEXT NULL,


    -- ========================================================
    -- ÍNDICES (NÃO UNIQUE)
    -- ========================================================

    INDEX idx_bronze_zsdbil17_rejected_rows_id_execucao (id_execucao(36)),

    INDEX idx_bronze_zsdbil17_rejected_rows_dt_carga (dt_carga(19))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'Linhas do CSV da Z17 rejeitadas pelo contrato do pré-processamento (APPEND por execução)';
