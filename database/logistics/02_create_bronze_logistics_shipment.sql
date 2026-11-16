-- ============================================================
-- TABELA: bp_datalake.bronze_logistics_shipment
-- CAMADA: Bronze (entrada manual pela tela do app logistics)
--
-- ORIGEM:
-- Tela Veículos > Logística (lançamento de embarque colado do
-- Excel ou digitado).
--
-- OBJETIVO:
-- Substitui a digitação nas abas por planta da planilha
-- PERFORMANCE GERAL. Cada lançamento é UMA linha: a situação de
-- um embarque num momento (aguardando, em trânsito, entregue,
-- retorno). Atualizar um embarque = lançar de novo a mesma NF com
-- a situação nova; a situação atual é o lançamento mais recente
-- da NF, e os anteriores ficam como histórico.
--
-- ESTRATÉGIA:
-- - Append-only: nada é editado nem apagado; cada gravação tem
--   uma linha REGISTER no bronze_logistics_shipment_audit_history.
-- - A NF é identificada pela chave do projeto (chassi + NF + data
--   de emissão + planta) e conferida na gold_zsdbil17_faturamento
--   antes de gravar. Modelo, cor, tipo de venda, dealer e destino
--   são copiados da Gold no momento do lançamento (foto), para a
--   Logística não digitar o que o faturamento já sabe.
--
-- DECISÕES:
-- - Tipos corretos (DATE, VARCHAR) e não TEXT: a tela valida
--   antes de gravar; não recebe arquivo externo (mesma exceção do
--   bronze_finance_credit_receipt e do cancelamento manual).
-- - Sem UNIQUE: a mesma NF recebe vários lançamentos ao longo do
--   embarque. Lançamento idêntico repetido é barrado pelo app.
-- - Sem FOREIGN KEY para a Gold: a Gold é regravada pela pipeline.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_logistics_shipment (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- NF (chave do projeto, conferida na Gold Z17)
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL
        COMMENT 'NF com 9 dígitos (zeros à esquerda)',
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    -- ========================================================
    -- EMBARQUE (o que a Logística informa)
    -- ========================================================

    carrier VARCHAR(30) NOT NULL
        COMMENT 'Transportadora (lista fechada do app)',
    warehouse VARCHAR(50) NULL
        COMMENT 'Pátio / armazém de saída (lista fechada do app)',
    pick_up_date DATE NULL
        COMMENT 'Data de coleta; obrigatória em EM_TRANSIT e DELIVERED',
    eta_date DATE NULL
        COMMENT 'Previsão de entrega',
    delivery_date DATE NULL
        COMMENT 'Entrega real (RTA da planilha); obrigatória em DELIVERED',
    shipment_status VARCHAR(30) NOT NULL
        COMMENT 'AWAITING_PICKUP, IN_TRANSIT, DELIVERED ou RETURNED',
    boarding_reason VARCHAR(80) NULL
        COMMENT 'Motivo do embarque / espera (BOARDING INFORMATION da planilha)',
    observation VARCHAR(255) NULL,

    -- ========================================================
    -- FOTO DA NF NA GOLD Z17 (no momento do lançamento)
    -- ========================================================

    model_description VARCHAR(255) NULL,
    color_description VARCHAR(50) NULL,
    sales_type_description VARCHAR(100) NULL
        COMMENT 'division_description da Gold',
    dealer_group VARCHAR(100) NULL,
    ship_to_party_name VARCHAR(100) NULL,
    ship_to_party_state CHAR(2) NULL,
    plant_description VARCHAR(100) NULL,

    -- ========================================================
    -- AUDITORIA
    -- ========================================================

    entry_source VARCHAR(20) NOT NULL DEFAULT 'APP',
    created_by VARCHAR(150) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    request_id CHAR(32) NOT NULL
        COMMENT 'Mesmo valor para todas as linhas de um lote',

    -- ========================================================
    -- ÍNDICES
    -- ========================================================

    PRIMARY KEY (id),
    INDEX idx_bronze_logistics_shipment_key
        (chassis_serial_number, invoice_number, issuance_date, plant_code),
    INDEX idx_bronze_logistics_shipment_created (created_at),
    INDEX idx_bronze_logistics_shipment_request (request_id)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci

COMMENT = 'Lançamentos de embarque da tela Logística (append-only; situação atual = lançamento mais recente da NF)';
