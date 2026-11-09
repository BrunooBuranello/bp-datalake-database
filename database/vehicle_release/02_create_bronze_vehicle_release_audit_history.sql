-- ============================================================
-- TABELA: bp_datalake.bronze_vehicle_release_audit_history
-- CAMADA: Bronze (auditoria, padrão *_audit_history)
--
-- ORIGEM:
-- sp_sync_bronze_vehicle_release.
--
-- OBJETIVO:
-- Histórico de cada mudança de status de cada NF da Liberação.
-- Daqui sai "quantos dias o chassi ficou em cada status" e
-- "o que entrou/mudou em cada execução" (filtrando run_id).
--
-- ESTRATÉGIA:
-- Somente INSERT (append-only). Nunca UPDATE nem DELETE.
-- Uma linha por evento:
--   INSERTED          NF entrou na liberação pela 1ª vez
--   STATUS_CHANGED    status mudou
--   REMOVED_FROM_GOLD NF saiu da Gold (cancelada/refaturada)
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release_audit_history (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- EXECUÇÃO
    -- ========================================================

    run_id BIGINT NOT NULL
        COMMENT 'Execução em bronze_vehicle_release_run_audit_history',
    triggered_by VARCHAR(150) NOT NULL
        COMMENT 'Usuário do app que clicou, ou pipeline',

    -- ========================================================
    -- CHAVE DA NF
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    -- ========================================================
    -- EVENTO
    -- ========================================================

    change_type VARCHAR(30) NOT NULL
        COMMENT 'INSERTED, STATUS_CHANGED, REMOVED_FROM_GOLD',
    old_status VARCHAR(30) NULL,
    new_status VARCHAR(30) NOT NULL,
    status_reason VARCHAR(500) NULL,
    credit_consumed_amount DECIMAL(15,2) NULL
        COMMENT 'Crédito consumido no evento (VD, fase 2)',
    changed_at DATETIME NOT NULL,

    PRIMARY KEY (id),

    INDEX idx_vehicle_release_audit_run (run_id),
    INDEX idx_vehicle_release_audit_chassis (chassis_serial_number),
    INDEX idx_vehicle_release_audit_changed_at (changed_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Liberação de Veículos: histórico append-only de mudanças de status por NF';
