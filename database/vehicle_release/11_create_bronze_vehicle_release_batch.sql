-- ============================================================
-- TABELAS: bp_datalake.bronze_vehicle_release_batch
--          bp_datalake.bronze_vehicle_release_batch_item
-- CAMADA: Bronze
--
-- OBJETIVO:
-- Guardar cada "Registrar liberação" em lote do app (13/11/2026):
-- quem pediu, quando, qual arquivo de crédito do Financeiro estava
-- carregado naquele momento, para quem foi o e-mail e, por NF, a
-- foto do que foi conferido (BASE do Financeiro, prazo, CRM).
--
-- Substitui a paridade com a planilha da colega: a conferência
-- passa a ser por amostra, e o lote guarda a prova do momento.
--
-- MODO:
-- - TEST: só grava o lote e manda o e-mail para quem clicou.
--   Não muda o status de nenhuma NF.
-- - PRODUCTION: também libera as NFs (RELEASED / APP), via
--   bronze_vehicle_release_manual_release (ver procedure 12).
--
-- Append-only: nunca apagar nem editar o lote, só o resultado do
-- e-mail (procedure 13).
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release_batch (

    batch_id BIGINT NOT NULL AUTO_INCREMENT,

    batch_mode VARCHAR(10) NOT NULL
        COMMENT 'TEST = só e-mail para quem clicou; PRODUCTION = libera as NFs',
    requested_by VARCHAR(150) NOT NULL
        COMMENT 'Usuário do app que clicou em Registrar liberação',
    requested_at DATETIME NOT NULL,
    nfs_count INT NOT NULL,

    -- Arquivo de crédito do Financeiro consumido (última carga SUCCESS).
    finance_load_run_id BIGINT NULL
        COMMENT 'run_id em bronze_finance_credit_load_run_audit_history',
    finance_file_modified_at DATETIME NULL
        COMMENT 'Data/hora de modificação do arquivo lido pela carga',
    finance_loaded_at DATETIME NULL
        COMMENT 'Quando a carga terminou de gravar a BASE',

    email_status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        COMMENT 'PENDING, SENT ou ERROR',
    email_recipients VARCHAR(1000) NULL,
    email_subject VARCHAR(300) NULL,
    email_error VARCHAR(1000) NULL,
    email_finished_at DATETIME NULL,

    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (batch_id),
    INDEX idx_vehicle_release_batch_requested_at (requested_at),
    CONSTRAINT chk_vehicle_release_batch_mode
        CHECK (batch_mode IN ('TEST', 'PRODUCTION')),
    CONSTRAINT chk_vehicle_release_batch_email_status
        CHECK (email_status IN ('PENDING', 'SENT', 'ERROR'))
)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Lotes de liberação registrados no app (1 linha por clique)';


CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release_batch_item (

    id BIGINT NOT NULL AUTO_INCREMENT,
    batch_id BIGINT NOT NULL,

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    -- Foto da NF no momento do lote.
    release_status VARCHAR(30) NOT NULL
        COMMENT 'Status da NF quando entrou no lote (READY_TO_RELEASE)',
    division VARCHAR(5) NULL,
    is_rental_company CHAR(3) NULL,
    model_simplified VARCHAR(100) NULL,
    total_amount DECIMAL(18, 2) NULL,
    payment_term_days INT NULL,
    crm_order_no VARCHAR(100) NULL,
    crm_order_sub_status VARCHAR(100) NULL,

    -- Foto da BASE do Financeiro (texto como veio da planilha).
    finance_invoice_amount VARCHAR(50) NULL
        COMMENT 'Coluna "a pagar" da BASE',
    finance_amount_received VARCHAR(50) NULL,
    finance_due_date VARCHAR(50) NULL,
    finance_base_loaded_at VARCHAR(30) NULL
        COMMENT 'dt_carga da linha na BASE',

    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_vehicle_release_batch_item (
        batch_id, chassis_serial_number, invoice_number, issuance_date, plant_code
    ),
    INDEX idx_vehicle_release_batch_item_key (
        chassis_serial_number, invoice_number, issuance_date, plant_code
    ),
    CONSTRAINT fk_vehicle_release_batch_item_batch
        FOREIGN KEY (batch_id) REFERENCES bp_datalake.bronze_vehicle_release_batch (batch_id)
)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'NFs de cada lote de liberação, com a foto do que foi conferido';
