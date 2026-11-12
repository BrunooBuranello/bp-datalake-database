-- ============================================================
-- TABELA: bp_datalake.gold_finance_credit_receivable_run_audit_history
-- CAMADA: auditoria (padrão *_audit_history)
--
-- ORIGEM:
-- sp_sync_gold_finance_credit_receivable (uma linha por execução).
--
-- OBJETIVO:
-- Saber quando a base do AR / Crédito foi atualizada, por quem
-- (pipeline ou carga manual), quanto entrou, quanto saiu da Gold
-- e se deu erro. A tela mostra a última execução.
--
-- ESTRATÉGIA:
-- INSERT com run_status = RUNNING no início (fora da transação,
-- para sobreviver a ROLLBACK) e UPDATE único no fim com SUCCESS
-- ou ERROR (mesmo padrão da Liberação de Veículos).
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.gold_finance_credit_receivable_run_audit_history (

    run_id BIGINT NOT NULL AUTO_INCREMENT,

    trigger_source VARCHAR(20) NOT NULL
        COMMENT 'PIPELINE (fim da pipeline Z17) ou MANUAL (carga inicial / suporte)',
    triggered_by VARCHAR(150) NOT NULL,
    started_at DATETIME(6) NOT NULL,
    finished_at DATETIME(6) NULL,
    run_status VARCHAR(10) NOT NULL
        COMMENT 'RUNNING, SUCCESS, ERROR',
    error_code INT NULL,
    error_message TEXT NULL,

    gold_rows_read INT NULL
        COMMENT 'NFs da Gold dentro do escopo nesta execução',
    nfs_inserted INT NULL,
    nfs_removed_from_gold INT NULL
        COMMENT 'NFs que saíram da Gold nesta execução (in_gold vira NO)',
    nfs_without_due_date INT NULL
        COMMENT 'NFs em escopo cuja condição de pagamento não tem prazo',
    total_rows_after INT NULL,

    PRIMARY KEY (run_id),

    INDEX idx_finance_credit_receivable_run_started_at (started_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'AR / Crédito: uma linha por execução da sp_sync_gold_finance_credit_receivable';
