-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_base
-- CAMADA: Bronze
--
-- ORIGEM:
-- Aba BASE da planilha de controle de crédito do Financeiro
-- (CRÉDITO DEALER ..._new distribution.xlsx). A carga será feita
-- por um script a ser mapeado (09/11/2026: estrutura criada vazia).
--
-- OBJETIVO:
-- Lista das NFs que o Financeiro já contabilizou no controle de
-- crédito. Regra 1 da Liberação: a chave chassi + NF + data de
-- faturamento precisa existir aqui.
--
-- ESTRATÉGIA:
-- TRUNCATE_INSERT (foto da planilha). Campos TEXT: arquivo manual,
-- a inconsistência da origem não pode impedir a carga; a
-- normalização (NF com 9 dígitos, data) é feita na leitura.
-- Mudanças entre cargas vão para
-- bronze_finance_credit_base_audit_history.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_base (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- CHAVE DA NF (sem planta: a BASE não traz a planta)
    -- ========================================================

    chassis TEXT NULL,
    invoice_number TEXT NULL,
    issuance_date TEXT NULL,

    -- ========================================================
    -- CLIENTE / VALOR
    -- ========================================================

    customer_cnpj TEXT NULL,
    invoice_amount TEXT NULL,

    -- ========================================================
    -- AUDITORIA DA INGESTÃO
    -- ========================================================

    dt_carga TEXT NULL,
    source_file TEXT NULL,
    source_sheet TEXT NULL,
    usuario TEXT NULL,

    PRIMARY KEY (id),

    INDEX idx_bronze_finance_credit_base_chassis (chassis(17))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'BASE do controle de crédito do Financeiro: NFs contabilizadas (chassi+NF+data)';
