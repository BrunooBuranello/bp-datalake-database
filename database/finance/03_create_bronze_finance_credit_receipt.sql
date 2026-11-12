-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_receipt
-- CAMADA: Bronze (entrada manual pela tela do app finance)
--
-- ORIGEM:
-- - tela Financeiro > AR / Crédito (lançamento de recebimento);
-- - carga única do saldo inicial a partir da coluna "Recebido" da
--   planilha (sp_load_finance_credit_opening_balance).
--
-- OBJETIVO:
-- Substitui a aba CARS da planilha. Cada recebimento é UMA linha
-- (livro-razão): uma NF pode receber vários pagamentos, e cada
-- valor fica com quem lançou e quando.
--
-- ESTRATÉGIA:
-- Append-only. Lançamento errado não é editado nem apagado: é
-- ESTORNADO (active = 0, com motivo), e o estorno vai para o
-- bronze_finance_credit_receipt_audit_history.
-- received_amount da gold_finance_credit_receivable é a soma das
-- linhas ativas, atualizada na mesma transação.
--
-- DECISÕES:
-- - Tipos corretos (DATE, DECIMAL) e não TEXT: a tela valida antes
--   de gravar; não recebe arquivo externo (exceção ao padrão TEXT
--   da Bronze, como o cancelamento manual).
-- - Sem FOREIGN KEY para a receivable: a receivable é regravada
--   pela pipeline; o app confere a chave antes de gravar.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_receipt (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- NF (chave do projeto, resolvida pelo app)
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    -- ========================================================
    -- O QUE O USUÁRIO DIGITOU
    -- ========================================================

    input_key_type VARCHAR(20) NOT NULL
        COMMENT 'LEGACY_KEY (CHASSI-NF), INVOICE_KEY (chassi+NF+data+planta) ou OPENING_BALANCE',
    input_key_text VARCHAR(100) NULL
        COMMENT 'Texto da chave como foi informado',

    -- ========================================================
    -- RECEBIMENTO
    -- ========================================================

    received_date DATE NULL
        COMMENT 'Data em que o dinheiro entrou; NULL só no saldo inicial (planilha não tinha)',
    received_amount DECIMAL(15,2) NOT NULL,
    observation VARCHAR(255) NULL,
    entry_source VARCHAR(20) NOT NULL
        COMMENT 'APP ou LEGACY_SPREADSHEET (saldo inicial)',

    -- ========================================================
    -- ESTADO E AUDITORIA DA LINHA
    -- ========================================================

    active TINYINT(1) NOT NULL DEFAULT 1
        COMMENT '0 = estornado',
    created_by VARCHAR(150) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reversed_by VARCHAR(150) NULL,
    reversed_at DATETIME NULL,
    reversal_reason VARCHAR(255) NULL,
    request_id CHAR(32) NULL
        COMMENT 'Liga os lançamentos gravados no mesmo envio da tela',

    PRIMARY KEY (id),

    INDEX idx_finance_credit_receipt_invoice_key (
        chassis_serial_number,
        invoice_number,
        issuance_date,
        plant_code
    ),
    INDEX idx_finance_credit_receipt_created_at (created_at),
    INDEX idx_finance_credit_receipt_entry_source (entry_source)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'AR / Crédito: lançamentos de recebimento por NF (livro-razão, estorno em vez de apagar)';
