-- ============================================================
-- TABELA: silver_zsdbil17_chassis_fallback
-- CAMADA: Silver (qualidade de dados)
--
-- ORIGEM:
-- Linhas da silver_zsdbil17_outbound_movements que nenhuma regra
-- de chassi conseguiu resolver (chassis_rule = FALLBACK_*), gravadas
-- por sp_silver_z17_chassis_resolution (ADR-016 do sap_service).
--
-- OBJETIVO:
-- Nenhum faturamento de veículo some calado. Cada linha aqui é um
-- caso aberto para alguém resolver (cadastrar material, corrigir no
-- SAP, explicar o caso). Quando o caso é resolvido, a linha sai
-- sozinha na próxima pipeline.
--
-- ESTRATÉGIA:
-- - Só casos ABERTOS (não é histórico): a cada pipeline a procedure
--   remove o que foi resolvido, insere o que é novo e atualiza
--   last_seen_at do que continua aberto.
-- - first_seen_at fica fixo desde a primeira vez que o caso apareceu.
--   O alarme do WeCom (Fase 2) olha só os casos novos, senão os
--   casos antigos deixariam a Z17 em alerta para sempre.
--
-- CHAVE:
-- UNIQUE (id_bronze), com justificativa: é uma linha por linha da
-- Silver. O id_bronze não muda entre cargas (a Bronze nunca apaga
-- nem reinsere documentos já conhecidos) e leva à linha completa na
-- Silver e na Bronze. Para identificar a NF use a regra da Z17:
-- chassi + NF + data + planta (aqui sem chassi, por definição).
--
-- Sem nome nem CNPJ/CPF de cliente: o id_bronze já leva ao detalhe.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.silver_zsdbil17_chassis_fallback (

    -- ========================================================
    -- IDENTIFICAÇÃO DA LINHA
    -- ========================================================

    id_bronze BIGINT NOT NULL,

    invoice_number VARCHAR(50) NULL,

    issuance_date DATE NULL,

    plant_code VARCHAR(10) NULL,

    so_item VARCHAR(20) NULL,


    -- ========================================================
    -- O QUE É A LINHA
    -- ========================================================

    sales_order_type VARCHAR(10) NULL,

    cfop VARCHAR(10) NULL,

    material VARCHAR(50) NULL,

    description VARCHAR(255) NULL,

    -- Tipo pela dim_material_classification no momento da regra
    -- (NULL = material sem classificação).
    material_type VARCHAR(20) NULL,

    -- Grupo de material do SAP na própria linha (B1 = peça, G1 = veículo).
    material_group_2 VARCHAR(10) NULL,


    -- ========================================================
    -- SINAIS DE VENDA
    -- ========================================================

    sales_order_number VARCHAR(20) NULL,

    billing_number_vf01 VARCHAR(20) NULL,

    item_total_net_price DECIMAL(18,2) NULL,


    -- ========================================================
    -- CANDIDATOS A CHASSI
    -- ========================================================

    chassis_serial_number VARCHAR(100) NULL,

    chassi_do_veiculo VARCHAR(100) NULL,

    customer_reference VARCHAR(100) NULL,


    -- ========================================================
    -- DIAGNÓSTICO
    -- ========================================================

    -- FALLBACK_MATERIAL_GROUP_CONFLICT, FALLBACK_VIN_CONFLICT,
    -- FALLBACK_VEHICLE_WITHOUT_VIN, FALLBACK_VEHICLE_MATERIAL_NOT_REGISTERED,
    -- FALLBACK_MATERIAL_UNCLASSIFIED.
    fallback_reason VARCHAR(50) NOT NULL,


    -- ========================================================
    -- CONTROLE
    -- ========================================================

    source_file VARCHAR(255) NULL,

    first_seen_at DATETIME(6) NOT NULL,

    last_seen_at DATETIME(6) NOT NULL,


    UNIQUE KEY uq_silver_zsdbil17_chassis_fallback_id_bronze (id_bronze),

    INDEX idx_silver_zsdbil17_chassis_fallback_reason (fallback_reason),

    INDEX idx_silver_zsdbil17_chassis_fallback_first_seen (first_seen_at)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci

COMMENT = 'Casos abertos de linhas da Silver Z17 sem regra de chassi (FALLBACK_*); some quando o caso é resolvido';
