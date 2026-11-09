-- ============================================================
-- TABELA: bp_datalake.bronze_vehicle_release
-- CAMADA: Bronze (gerada por procedure, a partir da Gold)
--
-- ORIGEM:
-- sp_sync_bronze_vehicle_release, que lê:
--   - gold_zsdbil17_faturamento (faturamento, um por chassi);
--   - dim_cond_pagamento (prazo em dias);
--   - dwd_sal_slm_base_order_details (pedido de dealer no CRM);
--   - bronze_finance_credit_base (BASE do controle de crédito);
--   - bronze_chassis_released_to_logistics (histórico manual).
--
-- OBJETIVO:
-- Foto atual da Liberação de Veículos: em que status cada NF
-- está e desde quando. Substitui o Google Sheets/Liberação.xlsm.
--
-- ESTRATÉGIA:
-- Upsert a cada execução (pipeline Z17 ou botão do app).
-- Uma linha por NF: chassi + NF + data de emissão + planta.
-- Cada mudança de status também vai para
-- bronze_vehicle_release_audit_history.
--
-- DECISÕES:
-- - Tipos corretos (DATE, DECIMAL, VARCHAR) e não TEXT: a tabela
--   nasce da Gold, já tipada; não recebe arquivo externo.
-- - UNIQUE na chave da NF: a procedure garante uma linha por NF
--   (exceção à regra "Bronze sem UNIQUE", justificada aqui).
-- - Grupo 1 (Revenda B1, Test Drive B2, locadoras) nesta fase.
--   Grupo 2 (Venda Direta B5, PCD B3, Táxi B4) virá depois.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- CHAVE DA NF (regra do projeto: nunca só chassi + NF)
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL
        COMMENT 'NF com 9 dígitos e zeros à esquerda',
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,
    proc_time TIME NULL
        COMMENT 'Horário da NF no SAP; desempate do FIFO',

    -- ========================================================
    -- TIPO DE VENDA
    -- ========================================================

    division VARCHAR(5) NULL
        COMMENT 'B1 Resale, B2 Test Drive, B3 PCD, B4 Taxi, B5 Direct Sale',
    division_description VARCHAR(100) NULL,
    release_group VARCHAR(10) NOT NULL
        COMMENT 'GROUP_1 = Revenda/Test Drive/Locadora; GROUP_2 = VD/PCD/Taxi',
    is_rental_company CHAR(3) NOT NULL DEFAULT 'NO'
        COMMENT 'YES quando o CNPJ está na lista de locadoras do app',

    -- ========================================================
    -- CLIENTE / DEALER
    -- ========================================================

    sold_to_party_code VARCHAR(20) NULL,
    sold_to_party_cnpj CHAR(14) NULL,
    sold_to_party_name VARCHAR(100) NULL,
    ship_to_party_code VARCHAR(20) NULL,
    ship_to_party_cnpj CHAR(14) NULL,
    ship_to_party_name VARCHAR(100) NULL,
    dealer_group VARCHAR(100) NULL,
    store_name_crm VARCHAR(100) NULL,

    -- ========================================================
    -- VEÍCULO
    -- ========================================================

    material VARCHAR(12) NULL,
    model_simplified VARCHAR(100) NULL,

    -- ========================================================
    -- REGRA 2: PRAZO DE PAGAMENTO (> 30 dias)
    -- ========================================================

    total_amount DECIMAL(15,2) NULL,
    payment_condition VARCHAR(10) NULL
        COMMENT 'Código SAP da condição (ex.: TDB9)',
    payment_term_days SMALLINT NULL
        COMMENT 'Dias da condição: dim_cond_pagamento ou texto SAP "dentro de N dias"',
    payment_term_ok CHAR(3) NULL
        COMMENT 'YES quando payment_term_days > 30',

    -- ========================================================
    -- REGRA 1: BASE DO FINANCEIRO (chassi + NF + data)
    -- ========================================================

    finance_base_found CHAR(3) NOT NULL DEFAULT 'NO',
    finance_base_loaded_at DATETIME NULL
        COMMENT 'Data da carga da BASE usada nesta avaliação',

    -- ========================================================
    -- REGRA 3: CRM (chassi + NF + data -> 1 pedido)
    -- ========================================================

    crm_match_count TINYINT NOT NULL DEFAULT 0
        COMMENT '0 = sem pedido; 1 = ok; >1 = ambíguo (revisão)',
    crm_order_no VARCHAR(100) NULL,
    crm_order_status VARCHAR(100) NULL,
    crm_order_sub_status VARCHAR(100) NULL
        COMMENT 'To Be Shipped = confirmado e pronto para expedir',
    crm_loaded_at DATETIME NULL
        COMMENT 'dt_carga do CRM usada nesta avaliação',

    -- ========================================================
    -- GRUPO 2 / VD (fase 2, ainda não preenchido)
    -- ========================================================

    crm_payment_completed CHAR(3) NULL,
    early_shipment_credit CHAR(3) NULL,
    credit_consumed_amount DECIMAL(15,2) NULL,

    -- ========================================================
    -- STATUS
    -- ========================================================

    release_status VARCHAR(30) NOT NULL
        COMMENT 'READY_TO_RELEASE, WAITING_FINANCE, WAITING_CRM, REVIEW_PAYMENT_TERM, RELEASED, NOT_IN_GOLD',
    release_status_reason VARCHAR(500) NULL
        COMMENT 'Todas as regras que falharam, em texto para o usuário',
    released_source VARCHAR(30) NULL
        COMMENT 'LEGACY_HISTORY (planilha antiga), CRM_STATUS (pedido já saiu) ou APP',
    in_gold CHAR(3) NOT NULL DEFAULT 'YES'
        COMMENT 'NO quando a NF saiu da Gold (cancelada/refaturada)',
    status_since DATETIME NOT NULL
        COMMENT 'Desde quando está no status atual (aging)',
    first_seen_at DATETIME NOT NULL,

    -- ========================================================
    -- CONTROLE
    -- ========================================================

    last_run_id BIGINT NOT NULL
        COMMENT 'run_id de bronze_vehicle_release_run_audit_history',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),

    UNIQUE KEY uk_vehicle_release_invoice_key (
        chassis_serial_number,
        invoice_number,
        issuance_date,
        plant_code
    ),

    INDEX idx_vehicle_release_status (release_status),
    INDEX idx_vehicle_release_issuance_date (issuance_date)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Liberação de Veículos: status atual de cada NF (chassi+NF+data+planta) gerado da Gold';
