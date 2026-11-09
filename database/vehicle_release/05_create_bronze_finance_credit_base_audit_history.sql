-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_base_audit_history
-- CAMADA: Bronze (auditoria, padrão *_audit_history)
--
-- ORIGEM:
-- Comparação entre a carga nova e a anterior da
-- bronze_finance_credit_base. A rotina que grava será definida
-- junto com o script de carga da BASE (estrutura criada vazia
-- em 09/11/2026).
--
-- OBJETIVO:
-- Saber o que o Financeiro incluiu, removeu ou alterou na BASE
-- entre uma carga e outra (quem carregou, quando, qual arquivo).
--
-- ESTRATÉGIA:
-- Somente INSERT (append-only). Uma linha por diferença:
--   INSERTED  chave nova na BASE
--   REMOVED   chave que saiu da BASE
--   CHANGED   CNPJ ou valor diferente para a mesma chave
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_base_audit_history (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- CHAVE DA NF (normalizada: NF com 9 dígitos, data DATE)
    -- ========================================================

    chassis VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NULL,

    -- ========================================================
    -- DIFERENÇA
    -- ========================================================

    change_type VARCHAR(10) NOT NULL
        COMMENT 'INSERTED, REMOVED, CHANGED',
    old_customer_cnpj VARCHAR(14) NULL,
    new_customer_cnpj VARCHAR(14) NULL,
    old_invoice_amount DECIMAL(15,2) NULL,
    new_invoice_amount DECIMAL(15,2) NULL,

    -- ========================================================
    -- CARGA QUE GEROU A DIFERENÇA
    -- ========================================================

    source_file VARCHAR(255) NULL,
    loaded_by VARCHAR(150) NULL,
    detected_at DATETIME NOT NULL,

    PRIMARY KEY (id),

    INDEX idx_finance_credit_audit_chassis (chassis),
    INDEX idx_finance_credit_audit_detected_at (detected_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Auditoria da BASE do Financeiro: chaves incluídas, removidas ou alteradas entre cargas';
