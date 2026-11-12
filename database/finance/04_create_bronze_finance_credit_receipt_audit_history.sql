-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_receipt_audit_history
-- CAMADA: auditoria (padrão *_audit_history)
--
-- ORIGEM:
-- app finance (lançamento e estorno) e
-- sp_load_finance_credit_opening_balance (saldo inicial).
--
-- OBJETIVO:
-- Quem lançou ou estornou cada recebimento, quando, em qual NF e
-- com qual valor. Append-only: nunca recebe UPDATE ou DELETE.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_receipt_audit_history (

    id BIGINT NOT NULL AUTO_INCREMENT,

    receipt_id BIGINT NOT NULL
        COMMENT 'id de bronze_finance_credit_receipt',

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    action_type VARCHAR(20) NOT NULL
        COMMENT 'REGISTER (lançamento), REVERSE (estorno), OPENING_BALANCE (saldo inicial)',
    received_amount DECIMAL(15,2) NOT NULL,
    received_date DATE NULL,
    reason VARCHAR(255) NULL
        COMMENT 'Observação do lançamento ou motivo do estorno',

    changed_by VARCHAR(150) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    request_id CHAR(32) NULL,

    PRIMARY KEY (id),

    INDEX idx_finance_credit_receipt_audit_receipt (receipt_id),
    INDEX idx_finance_credit_receipt_audit_changed_at (changed_at),
    INDEX idx_finance_credit_receipt_audit_chassis (chassis_serial_number)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'AR / Crédito: auditoria append-only dos lançamentos e estornos de recebimento';
