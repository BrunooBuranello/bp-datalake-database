-- ============================================================
-- TABELA: bp_datalake.bronze_vehicle_release_run_audit_history
-- CAMADA: Bronze (auditoria, padrão *_audit_history)
--
-- ORIGEM:
-- sp_sync_bronze_vehicle_release (uma linha por execução).
--
-- OBJETIVO:
-- Saber quem disparou a criação da bronze_vehicle_release,
-- quando, por onde (pipeline ou botão), quanto entrou/mudou,
-- a foto dos totais por status, se o CRM estava atualizado no
-- dia e quanto crédito foi consumido (VD, fase 2).
--
-- ESTRATÉGIA:
-- INSERT com run_status = RUNNING no início (fora da transação,
-- para sobreviver a ROLLBACK) e UPDATE único no fim com
-- SUCCESS ou ERROR. Não usa etl_execution_log (decisão do Bruno,
-- 09/11/2026): aqui fica o usuário do app, não o do banco.
-- O run_id liga com bronze_vehicle_release_audit_history.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release_run_audit_history (

    run_id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- QUEM / QUANDO / COMO
    -- ========================================================

    trigger_source VARCHAR(20) NOT NULL
        COMMENT 'PIPELINE (fim da pipeline Z17) ou BUTTON (app)',
    triggered_by VARCHAR(150) NOT NULL,
    started_at DATETIME(6) NOT NULL,
    finished_at DATETIME(6) NULL,
    run_status VARCHAR(10) NOT NULL
        COMMENT 'RUNNING, SUCCESS, ERROR',
    error_code INT NULL,
    error_message TEXT NULL,

    -- ========================================================
    -- O QUE ENTROU / MUDOU NESTA EXECUÇÃO
    -- ========================================================

    start_issuance_date DATE NULL
        COMMENT 'Corte: só NFs emitidas a partir desta data',
    gold_rows_read INT NULL,
    nfs_inserted INT NULL,
    status_changes INT NULL,
    nfs_removed_from_gold INT NULL,

    -- ========================================================
    -- FOTO DOS TOTAIS POR STATUS (após a execução)
    -- ========================================================

    qty_ready_to_release INT NULL,
    qty_waiting_finance INT NULL,
    qty_waiting_crm INT NULL,
    qty_review_payment_term INT NULL,
    qty_released INT NULL,
    qty_not_in_gold INT NULL,

    -- ========================================================
    -- FRESCOR DAS FONTES
    -- ========================================================

    crm_last_load_at DATETIME NULL,
    crm_is_fresh CHAR(3) NULL
        COMMENT 'YES quando o CRM foi carregado hoje (mesma data da execução)',
    finance_base_last_load_at DATETIME NULL,
    finance_base_rows INT NULL,

    -- ========================================================
    -- CRÉDITO (VD, fase 2)
    -- ========================================================

    credit_consumed_total DECIMAL(15,2) NULL,

    PRIMARY KEY (run_id),

    INDEX idx_vehicle_release_run_started_at (started_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Liberação de Veículos: uma linha por execução (quem, quando, totais, frescor das fontes)';
