-- ============================================================
-- TABELA: bp_datalake.bronze_logistics_shipment_audit_history
-- CAMADA: Bronze (auditoria)
--
-- ORIGEM:
-- App logistics, na mesma transação de cada lançamento.
--
-- OBJETIVO:
-- Responder "quem lançou o quê, quando e em qual lote" sem
-- depender da tabela de lançamentos. Padrão _audit_history do
-- projeto (cancelamento manual, AR / Crédito, Liberação).
--
-- ESTRATÉGIA:
-- Append-only. Uma linha por lançamento (action_type REGISTER).
-- Ações futuras (ex.: estorno) entram com outro action_type.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_logistics_shipment_audit_history (

    id BIGINT NOT NULL AUTO_INCREMENT,

    shipment_id BIGINT NOT NULL
        COMMENT 'id em bronze_logistics_shipment',

    -- ========================================================
    -- NF
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    -- ========================================================
    -- AÇÃO
    -- ========================================================

    action_type VARCHAR(20) NOT NULL
        COMMENT 'REGISTER',
    shipment_status VARCHAR(30) NOT NULL,
    carrier VARCHAR(30) NOT NULL,
    changed_by VARCHAR(150) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    request_id CHAR(32) NOT NULL,

    PRIMARY KEY (id),
    INDEX idx_bronze_logistics_shipment_audit_shipment (shipment_id),
    INDEX idx_bronze_logistics_shipment_audit_chassis (chassis_serial_number),
    INDEX idx_bronze_logistics_shipment_audit_changed (changed_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci

COMMENT = 'Quem lançou cada embarque na tela Logística, quando e em qual lote';
