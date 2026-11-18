-- ============================================================
-- TABELA: bronze_zfiglm_48b_overdue
-- CAMADA: Bronze
--
-- ORIGEM:
-- Transação SAP ZFIGLM_48B, botão "Overdue" (BUT06), empresas BR00 a
-- BR70, exportada em CSV pelo BYD Sales Operation
-- (sap_service/services/transactions/zfiglm_48b.py, ADR-034 do
-- sap_service). Arquivo de origem: ZFIGLM_48B_AAAAMMDD_HHMMSS.csv.
--
-- OBJETIVO:
-- Guardar a posição de NFs vencidas (overdue) por data-base, fiel ao
-- SAP, para consulta e para futuras camadas Silver/Gold.
--
-- ESTRATÉGIA:
-- - APPEND a cada execução (sem DELETE nem TRUNCATE), a pedido do
--   Bruno (17/11/2026). Roda de hora em hora no lote "SAP Jobs" e
--   pelo botão da tela Transações SAP.
-- - Duplicidades esperadas: cada execução grava a foto inteira de novo.
--   Para a foto mais recente, filtrar pelo id_execucao do maior dt_carga.
-- - Todas as colunas TEXT (padrão Bronze): nomes iguais ao cabeçalho do
--   CSV, normalizados para snake_case.
-- - Volume de referência: ~3,7 mil linhas por execução (17/11/2026).
--
-- APLICAR ANTES do deploy do app que grava nesta tabela. Sem a tabela,
-- a carga da ZFIGLM_48B falha (o CSV continua disponível para download).
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_zfiglm_48b_overdue (

    -- ========================================================
    -- COLUNAS DO SAP (ordem do CSV)
    -- ========================================================

    -- Empresa
    empresa TEXT NULL,

    -- Modelo
    modelo TEXT NULL,

    -- Número do Chassi
    numero_do_chassi TEXT NULL,

    -- Número da NF
    numero_da_nf TEXT NULL,

    -- Data do Faturamento
    data_do_faturamento TEXT NULL,

    -- Grupo Dealer
    grupo_dealer TEXT NULL,

    -- Ship to Party Name
    ship_to_party_name TEXT NULL,

    -- Cliente
    cliente TEXT NULL,

    -- UF
    uf TEXT NULL,

    -- Condição de pagamento
    condicao_de_pagamento TEXT NULL,

    -- Data de vencimento
    data_de_vencimento TEXT NULL,

    -- Quantos dias em overdue
    quantos_dias_em_overdue TEXT NULL,

    -- Client CNPJ
    client_cnpj TEXT NULL,

    -- Valor da NF
    valor_da_nf TEXT NULL,

    -- Pago
    pago TEXT NULL,

    -- Data de pagamento
    data_de_pagamento TEXT NULL,

    -- Data de emplacamento
    data_de_emplacamento TEXT NULL,

    -- Código do cliente
    codigo_do_cliente TEXT NULL,

    -- Crédito
    credito TEXT NULL,

    -- Cancelado
    cancelado TEXT NULL,

    -- Status Overdue
    status_overdue TEXT NULL,

    -- Valor overdue
    valor_overdue TEXT NULL,

    -- Canal de vendas
    canal_de_vendas TEXT NULL,

    -- Detalhe do canal de vendas
    detalhe_do_canal_de_vendas TEXT NULL,

    -- Aging
    aging TEXT NULL,

    -- Documento de faturamento
    documento_de_faturamento TEXT NULL,

    -- Número de documento do SAP
    numero_de_documento_do_sap TEXT NULL,

    -- YEAR
    year TEXT NULL,

    -- BYD CNPJ
    byd_cnpj TEXT NULL,

    -- Key reference
    key_reference TEXT NULL,

    -- Tipo de ordem
    tipo_de_ordem TEXT NULL,

    -- CRM Sales Order
    crm_sales_order TEXT NULL,


    -- ========================================================
    -- AUDITORIA
    -- ========================================================

    -- Data-base informada na transação (AAAA-MM-DD). Agendado = dia
    -- da execução; botão = data escolhida pelo usuário.
    reference_date TEXT NULL,

    -- Data/hora da carga (AAAA-MM-DD HH:MM:SS).
    dt_carga TEXT NULL,

    -- job_id da execução no BYD Sales Operation.
    id_execucao TEXT NULL,

    -- Arquivo exportado do SAP (ZFIGLM_48B_AAAAMMDD_HHMMSS.csv).
    source_file TEXT NULL,

    -- "scheduler" (orquestrador) ou o login de quem apertou o botão.
    usuario TEXT NULL,


    -- ========================================================
    -- ÍNDICES (NÃO UNIQUE)
    -- ========================================================

    INDEX idx_bronze_zfiglm_48b_overdue_numero_do_chassi (numero_do_chassi(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_numero_da_nf (numero_da_nf(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_client_cnpj (client_cnpj(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_codigo_do_cliente (codigo_do_cliente(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_documento_de_faturamento (documento_de_faturamento(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_numero_de_documento_do_sap (numero_de_documento_do_sap(20)),

    INDEX idx_bronze_zfiglm_48b_overdue_reference_date (reference_date(10)),

    INDEX idx_bronze_zfiglm_48b_overdue_id_execucao (id_execucao(36))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'ZFIGLM_48B Overdue (SAP), APPEND por execução com data-base e auditoria';
