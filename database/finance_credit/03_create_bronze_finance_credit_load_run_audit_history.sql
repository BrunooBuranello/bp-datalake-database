-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_load_run_audit_history
-- CAMADA: Bronze (auditoria, append-only)
--
-- ORIGEM:
-- Integração finance_credit do BYD Sales Operation
-- (data_integrations, ADR-004).
--
-- OBJETIVO:
-- Uma linha por execução da carga da planilha de crédito do
-- Financeiro. Responde "de onde veio este número?": qual arquivo
-- (nome, tamanho, data de modificação e SHA-256 do arquivo
-- criptografado como está na rede), quem/o que disparou, quantas
-- linhas foram lidas, inseridas, removidas e alteradas, e por que
-- uma carga foi bloqueada ou falhou.
--
-- STATUS:
--   RUNNING  execução em andamento (ou interrompida sem finalizar)
--   SUCCESS  carga gravada
--   SKIPPED  arquivo idêntico à última carga com sucesso (mesmo
--            SHA-256): nada a gravar
--   BLOCKED  validação barrou a carga (ex.: tiraria mais de 20% das
--            linhas, cabeçalho mudou); nada foi gravado
--   ERROR    erro inesperado; nada foi gravado (transação desfeita)
--
-- DECISÕES:
-- - Tipos corretos (não TEXT): a tabela é escrita só pelo código.
-- - Sem dado de negócio aqui: só contagens e metadados do arquivo.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_load_run_audit_history (

    run_id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- QUEM / QUANDO
    -- ========================================================

    trigger_source VARCHAR(20) NOT NULL
        COMMENT 'SCHEDULER, COMMAND',
    triggered_by VARCHAR(150) NULL,
    integration_execution_id VARCHAR(64) NULL
        COMMENT 'DataIntegrationExecution.execution_id (Django)',
    started_at DATETIME(6) NOT NULL,
    finished_at DATETIME(6) NULL,
    run_status VARCHAR(10) NOT NULL
        COMMENT 'RUNNING, SUCCESS, SKIPPED, BLOCKED, ERROR',
    error_message TEXT NULL,

    -- ========================================================
    -- ARQUIVO DE ORIGEM
    -- ========================================================

    source_file_name VARCHAR(255) NULL,
    source_file_size_bytes BIGINT NULL,
    source_file_modified_at DATETIME NULL,
    source_file_sha256 CHAR(64) NULL
        COMMENT 'Hash do arquivo criptografado, como está na rede',

    -- ========================================================
    -- ABA BASE (bronze_finance_credit_base)
    -- ========================================================

    base_rows_read INT NULL,
    base_rows_without_key INT NULL
        COMMENT 'Linhas sem chassi de 17, NF numérica ou data',
    base_duplicate_keys INT NULL,
    base_rows_inserted INT NULL,
    base_rows_removed INT NULL,
    base_rows_changed INT NULL,
    base_rows_unchanged INT NULL,
    base_rows_after INT NULL,

    -- ========================================================
    -- ABAS CARTA DE CONCESSÃO + EMBARQUE ANTECIPADO
    -- (bronze_espelho_credito)
    -- ========================================================

    credit_rows_loaded INT NULL,
    credit_cnpj_flagged INT NULL
        COMMENT 'CNPJs com status diferente de VALIDO',

    -- ========================================================
    -- AVISOS
    -- ========================================================

    warnings TEXT NULL,

    PRIMARY KEY (run_id),
    INDEX idx_finance_credit_run_started_at (started_at),
    INDEX idx_finance_credit_run_status (run_status)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Execuções da carga da planilha de crédito do Financeiro (arquivo, contagens, status)';
