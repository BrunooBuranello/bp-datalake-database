-- ============================================================
-- TABELA: silver_va05_sales_order_channel
-- CAMADA: Silver (tipada + canal da ordem)
--
-- ORIGEM:
-- bp_datalake.bronze_va05_sales_order (SAP VA05), recalculada pela
-- sp_silver_va05_sales_order_channel para o período de cada execução.
--
-- OBJETIVO:
-- Dizer, por item de ordem de venda, por qual canal o pedido nasceu:
--   ONLINE_CRM      = criado pelo usuário de interface do CRM (RFC_BRCRM)
--   OTHER_INTERFACE = criado por outra interface (RFC_BRDMS01, RFC_BRMALL01,
--                     RFC_BRBSS01...): grupo à parte, nem CRM nem manual
--   OFFLINE_MANUAL  = criado por usuário pessoal BYD (MXSD*, HQMM*...)
--   UNKNOWN         = criado_por vazio (não deveria acontecer; fica visível
--                     em vez de virar offline por engano)
-- Regra definida pelo Bruno em 27/11/2026, a pedido do time CRM.
-- A ligação com o faturamento é sales_order_number = sales_order_number da
-- Z17 (Silver/Gold). O enriquecimento com a NF fica para o próximo passo.
--
-- ESTRATÉGIA:
-- - Grão: item da ordem (sales_order_number + sales_order_item), igual à
--   Bronze. UNIQUE nessa chave: a Bronze já garante um item por hash, então
--   a Silver só repete a garantia (proteção contra procedure errada).
-- - Tipos corretos (DATE, TIME, DECIMAL). Valor que não converte vira NULL
--   (o texto original continua na Bronze).
-- - Só as colunas úteis para canal, ordem, cliente, material e status; as
--   colunas sempre vazias (contrato, rescisão...) ficam só na Bronze.
-- - Carga por período: apaga e regrava as ordens com data do documento no
--   período da execução (DELETE + INSERT numa transação). Itens MISSING da
--   Bronze entram com source_status = 'MISSING' para não sumirem calados.
--
-- ROLLBACK:
--   DROP TABLE bp_datalake.silver_va05_sales_order_channel;
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.silver_va05_sales_order_channel (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- IDENTIFICAÇÃO DA ORDEM
    -- ========================================================
    sales_order_number VARCHAR(10) NOT NULL,          -- documento_de_vendas
    sales_order_item VARCHAR(6) NOT NULL,             -- item
    sales_order_type VARCHAR(4) NULL,                 -- tipo_doc_vendas (ZPJ1, ZBR3...)
    sales_order_type_description VARCHAR(60) NULL,
    sd_document_category VARCHAR(2) NULL,             -- ctg_documento_sd
    order_date DATE NULL,                             -- data_do_documento
    order_time TIME NULL,                             -- hora_registro
    created_on DATE NULL,                             -- criado_em
    customer_reference VARCHAR(35) NULL,              -- referencia_de_cliente (chassi nas ordens de carro)
    header_customer_reference VARCHAR(35) NULL,       -- referencia_de_cliente_cabecalho

    -- ========================================================
    -- CANAL (regra de negócio desta Silver)
    -- ========================================================
    created_by VARCHAR(12) NULL,                      -- criado_por (usuário SAP)
    order_channel VARCHAR(20) NOT NULL,               -- ONLINE_CRM | OTHER_INTERFACE | OFFLINE_MANUAL | UNKNOWN

    -- ========================================================
    -- ORGANIZAÇÃO DE VENDAS
    -- ========================================================
    sales_organization VARCHAR(4) NULL,
    distribution_channel VARCHAR(2) NULL,
    division VARCHAR(2) NULL,                         -- setor_de_atividade
    sales_office VARCHAR(4) NULL,
    sales_group VARCHAR(3) NULL,
    plant_code VARCHAR(4) NULL,                       -- centro
    storage_location VARCHAR(4) NULL,                 -- deposito
    shipping_point VARCHAR(4) NULL,                   -- local_expedicao_recebimento

    -- ========================================================
    -- CLIENTE
    -- ========================================================
    sold_to_party VARCHAR(10) NULL,                   -- emissor_da_ordem
    sold_to_name VARCHAR(80) NULL,                    -- nome_emissor_ordem

    -- ========================================================
    -- MATERIAL, QUANTIDADE E VALOR
    -- ========================================================
    material VARCHAR(40) NULL,
    material_description VARCHAR(80) NULL,
    order_quantity DECIMAL(15, 3) NULL,               -- quantidade_da_ordem_item
    confirmed_quantity DECIMAL(15, 3) NULL,           -- quantidade_confirmada_item
    sales_unit VARCHAR(3) NULL,
    net_value_item DECIMAL(18, 2) NULL,
    net_value_header DECIMAL(18, 2) NULL,
    net_price DECIMAL(18, 2) NULL,
    currency VARCHAR(5) NULL,

    -- ========================================================
    -- STATUS
    -- ========================================================
    overall_status VARCHAR(1) NULL,                   -- status_global
    overall_status_description VARCHAR(40) NULL,
    item_overall_status VARCHAR(1) NULL,
    item_overall_status_description VARCHAR(40) NULL,
    delivery_status VARCHAR(1) NULL,                  -- status_global_remessa_todos_os_itens
    delivery_status_description VARCHAR(40) NULL,

    -- ========================================================
    -- CONTROLE (vindo da Bronze)
    -- ========================================================
    source_status VARCHAR(10) NOT NULL,               -- ACTIVE | MISSING
    first_seen_at DATETIME NOT NULL,
    last_seen_at DATETIME NOT NULL,
    silver_loaded_at DATETIME NOT NULL,

    PRIMARY KEY (id),

    UNIQUE KEY uk_silver_va05_channel_order_item (sales_order_number, sales_order_item),

    -- Mesmas chaves de consulta da Bronze + canal.
    INDEX idx_silver_va05_channel_order_date (order_date),
    INDEX idx_silver_va05_channel_material (material),
    INDEX idx_silver_va05_channel_customer_reference (customer_reference),
    INDEX idx_silver_va05_channel_order_channel (order_channel),
    INDEX idx_silver_va05_channel_created_by (created_by)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'Itens de ordem de venda da VA05 tipados, com o canal (CRM online, outra interface ou manual offline)';
