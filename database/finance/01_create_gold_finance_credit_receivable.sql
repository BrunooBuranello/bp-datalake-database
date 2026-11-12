-- ============================================================
-- TABELA: bp_datalake.gold_finance_credit_receivable
-- CAMADA: Gold (gerada por procedure, a partir da Gold Z17)
--
-- ORIGEM:
-- sp_sync_gold_finance_credit_receivable, que lê:
--   - gold_zsdbil17_faturamento (NF, cliente, valor, condição);
--   - dim_cond_pagamento (prazo em dias para o vencimento).
-- O recebido vem dos lançamentos de bronze_finance_credit_receipt
-- (tela Financeiro > AR / Crédito).
--
-- OBJETIVO:
-- Contas a receber de veículos por NF: substitui a aba BASE da
-- planilha "CRÉDITO DEALER ... new distribution" do Financeiro
-- (ADR-001 do app finance).
--
-- ESCOPO (11/11/2026, todo o histórico da Gold):
--   - B1 Revenda, B2 Test Drive, B3 PCD, B4 Táxi, B5 Venda Direta;
--   - legado 2024/2025 com outros códigos de division: entra pela
--     descrição RESALE, TEST DRIVE ou DIRECT SALE.
-- Regras futuras (VD só com Carta de Concessão ou Embarque
-- Antecipado; DEMO Denza) ficam para outro ADR.
--
-- CLIENTE (customer_*):
--   Revenda e Test Drive -> sold-to; demais -> ship-to.
--
-- ESTRATÉGIA:
-- Upsert a cada execução (fim da pipeline Z17). Uma linha por NF:
-- chassi + NF + data de emissão + planta. NF que sai da Gold
-- (cancelada/refaturada) NÃO é apagada: fica com in_gold = 'NO',
-- porque pode ter recebimentos lançados.
--
-- DECISÕES:
-- - Tipos corretos e UNIQUE na chave (mesma exceção justificada da
--   bronze_vehicle_release): nasce da Gold já tipada.
-- - received_amount é a SOMA dos lançamentos ativos, mantida na
--   mesma transação de cada lançamento/estorno pelo app (e pela
--   carga do saldo inicial). A fonte da verdade é o lançamento;
--   esta coluna existe para a tela e o pivot não somarem ~400 mil
--   lançamentos a cada consulta. A procedure de sync NUNCA altera
--   received_amount. Conferência no README.
-- - open_amount e payment_status são colunas geradas (STORED):
--   nunca ficam diferentes do valor e do recebido.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.gold_finance_credit_receivable (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- CHAVE DA NF (regra do projeto: nunca só chassi + NF)
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL
        COMMENT 'NF com 9 dígitos e zeros à esquerda',
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,
    legacy_key VARCHAR(40) NOT NULL
        COMMENT 'Chave antiga da planilha: CHASSI-NF, NF sem zeros à esquerda',
    record_source VARCHAR(30) NOT NULL
        COMMENT 'ZSDBIL17_CURRENT ou LEGACY_2024_2025 (mesmo valor da Gold)',

    -- ========================================================
    -- TIPO DE VENDA
    -- ========================================================

    division VARCHAR(5) NULL,
    division_description VARCHAR(100) NULL,
    sales_type VARCHAR(20) NOT NULL
        COMMENT 'RESALE, TEST_DRIVE, PCD, TAXI, DIRECT_SALE',

    -- ========================================================
    -- CLIENTE (sold-to em Revenda/Test Drive; ship-to no resto)
    -- ========================================================

    customer_party_role VARCHAR(10) NOT NULL
        COMMENT 'SOLD_TO ou SHIP_TO: de qual parceiro da NF veio o cliente',
    customer_code VARCHAR(20) NULL,
    customer_cnpj CHAR(14) NULL,
    customer_cnpj_root CHAR(8) NULL
        COMMENT 'Raiz do CNPJ (8 primeiros dígitos) para o pivot por grupo',
    customer_name VARCHAR(100) NULL,
    dealer_group VARCHAR(100) NULL,

    -- ========================================================
    -- VEÍCULO
    -- ========================================================

    model_simplified VARCHAR(100) NULL,

    -- ========================================================
    -- VALOR E VENCIMENTO
    -- ========================================================

    total_amount DECIMAL(15,2) NULL
        COMMENT 'Valor total da NF (Z17); a pagar',
    payment_condition VARCHAR(10) NULL
        COMMENT 'Código SAP da condição de pagamento',
    payment_term_days SMALLINT NULL
        COMMENT 'Dias da condição: dim_cond_pagamento ou texto SAP "dentro de N dias"',
    due_date DATE NULL
        COMMENT 'issuance_date + payment_term_days; NULL quando a condição não tem prazo',

    -- ========================================================
    -- RECEBIDO (soma dos lançamentos ativos)
    -- ========================================================

    received_amount DECIMAL(15,2) NOT NULL DEFAULT 0
        COMMENT 'Soma dos lançamentos ativos de bronze_finance_credit_receipt',
    last_receipt_at DATETIME NULL
        COMMENT 'Último lançamento ou estorno nesta NF',
    open_amount DECIMAL(15,2)
        AS (COALESCE(total_amount, 0) - received_amount) STORED
        COMMENT 'Saldo: a pagar - recebido',
    payment_status VARCHAR(10)
        AS (
            CASE
                WHEN received_amount = 0 THEN 'OPEN'
                WHEN received_amount < COALESCE(total_amount, 0) THEN 'PARTIAL'
                WHEN received_amount = COALESCE(total_amount, 0) THEN 'PAID'
                ELSE 'OVERPAID'
            END
        ) STORED
        COMMENT 'OPEN, PARTIAL, PAID, OVERPAID',

    -- ========================================================
    -- CONTROLE
    -- ========================================================

    in_gold CHAR(3) NOT NULL DEFAULT 'YES'
        COMMENT 'NO quando a NF saiu da Gold (cancelada/refaturada)',
    first_seen_at DATETIME NOT NULL,
    last_run_id BIGINT NOT NULL
        COMMENT 'Execução que criou a NF ou a marcou fora da Gold (run_audit_history)',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),

    UNIQUE KEY uk_finance_credit_receivable_invoice_key (
        chassis_serial_number,
        invoice_number,
        issuance_date,
        plant_code
    ),

    -- Lançamento pela chave antiga (CHASSI-NF).
    INDEX idx_finance_credit_receivable_legacy_key (legacy_key),
    -- Pivot por CNPJ e por raiz.
    INDEX idx_finance_credit_receivable_cnpj (customer_cnpj),
    INDEX idx_finance_credit_receivable_cnpj_root (customer_cnpj_root),
    -- Filtros da tela.
    INDEX idx_finance_credit_receivable_status (payment_status),
    INDEX idx_finance_credit_receivable_issuance_date (issuance_date),
    INDEX idx_finance_credit_receivable_due_date (due_date)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'AR / Crédito: contas a receber por NF (chassi+NF+data+planta) gerado da Gold Z17';
