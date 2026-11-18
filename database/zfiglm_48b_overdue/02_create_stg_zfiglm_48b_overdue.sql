-- ============================================================
-- TABELA: stg_zfiglm_48b_overdue
-- CAMADA: Staging (snapshot atual)
--
-- ORIGEM:
-- CSV da ZFIGLM_48B (Overdue) exportado pelo BYD Sales Operation
-- (sap_service/services/workflows/zfiglm_48b.py, ADR-036 do sap_service).
--
-- OBJETIVO:
-- Receber SÓ a foto da última execução. O app faz TRUNCATE + INSERT aqui
-- e em seguida chama sp_stg_reconcile_zfiglm_48b_bronze, que reconcilia a
-- foto com o histórico da bronze_zfiglm_48b_overdue (mesmo desenho da Z17:
-- stg_zsdbil17_faturamento -> sp_stg_reconcile_zsdbil17_bronze).
--
-- REGRAS:
-- - Mesmas 32 colunas do SAP e 5 de auditoria da Bronze, todas TEXT.
-- - reconciliation_hash é preenchido pela procedure (não pelo app).
-- - Nível item: uma NF pode ter várias linhas iguais (uma por item).
--   Por isso NÃO existe chave única aqui.
--
-- APLICAR ANTES do deploy do app que grava nesta tabela.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.stg_zfiglm_48b_overdue (

    -- ========================================================
    -- COLUNAS DO SAP (ordem do CSV)
    -- ========================================================
    empresa TEXT NULL,
    modelo TEXT NULL,
    numero_do_chassi TEXT NULL,
    numero_da_nf TEXT NULL,
    data_do_faturamento TEXT NULL,
    grupo_dealer TEXT NULL,
    ship_to_party_name TEXT NULL,
    cliente TEXT NULL,
    uf TEXT NULL,
    condicao_de_pagamento TEXT NULL,
    data_de_vencimento TEXT NULL,
    quantos_dias_em_overdue TEXT NULL,
    client_cnpj TEXT NULL,
    valor_da_nf TEXT NULL,
    pago TEXT NULL,
    data_de_pagamento TEXT NULL,
    data_de_emplacamento TEXT NULL,
    codigo_do_cliente TEXT NULL,
    credito TEXT NULL,
    cancelado TEXT NULL,
    status_overdue TEXT NULL,
    valor_overdue TEXT NULL,
    canal_de_vendas TEXT NULL,
    detalhe_do_canal_de_vendas TEXT NULL,
    aging TEXT NULL,
    documento_de_faturamento TEXT NULL,
    numero_de_documento_do_sap TEXT NULL,
    year TEXT NULL,
    byd_cnpj TEXT NULL,
    key_reference TEXT NULL,
    tipo_de_ordem TEXT NULL,
    crm_sales_order TEXT NULL,

    -- ========================================================
    -- AUDITORIA (mesmo significado da Bronze)
    -- ========================================================
    reference_date TEXT NULL,
    dt_carga TEXT NULL,
    id_execucao TEXT NULL,
    source_file TEXT NULL,
    usuario TEXT NULL,

    -- ========================================================
    -- CONTROLE
    -- ========================================================

    -- MD5 de documento SAP + empresa + NF + data do faturamento
    -- (ADR-036). Preenchido pela procedure.
    reconciliation_hash BINARY(16) NULL,

    INDEX idx_stg_zfiglm_48b_overdue_hash (reconciliation_hash)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'ZFIGLM_48B Overdue (SAP), snapshot da última execução antes da reconciliação';
