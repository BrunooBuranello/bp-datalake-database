-- ============================================================
-- GOLD - DEMO HISTORY
-- ============================================================
-- Objetivo:
-- Manter histórico independente dos faturamentos DEMO
-- e das movimentações posteriores do mesmo chassi.
--
-- Fonte histórica:
-- bp_datalake.silver_zsdbil17_outbound_movements
--
-- Enriquecimentos adicionais:
-- bronze.mapping_dealer_expansion
--
-- A Silver é utilizada porque preserva o histórico das
-- movimentações do chassi antes da consolidação realizada
-- na Gold principal.
--
-- Cada nova movimentação relevante do mesmo chassi gera
-- um novo evento, preservando a fotografia daquele momento.
--
-- Um mesmo chassi pode possuir várias notas e também
-- mais de um ciclo DEMO ao longo do histórico.
--
-- A tabela NÃO possui FK para Silver ou Gold propositalmente.
-- O histórico deve sobreviver mesmo que as tabelas de origem
-- sejam reconstruídas ou alteradas.
-- ============================================================


CREATE TABLE IF NOT EXISTS bp_datalake.gold_zsdbil17_demo_history (

    -- ========================================================
    -- STATUS / CLASSIFICAÇÃO
    -- ========================================================

    -- Situação atual do ciclo DEMO:
    -- OPEN
    -- WARNING
    -- OVERDUE
    -- CLOSED
    demo_status VARCHAR(20) NOT NULL,

    -- Tipo do evento:
    -- DEMO
    -- REINVOICE
    -- CANCELLATION
    event_type VARCHAR(30) NOT NULL,

    -- Classificação enriquecida do tipo de venda.
    division_description_enriched VARCHAR(100) NULL,


    -- ========================================================
    -- CONTROLE OPERACIONAL BP
    -- ========================================================
    -- Campos mantidos pelo processo operacional.
    --
    -- Não devem ser sobrescritos pela procedure de
    -- sincronização do Demo History.
    -- ========================================================

    -- Controle do recebimento do retorno.
    return_received_status VARCHAR(30) NULL,

    -- Status operacional tratado pelo BP.
    bp_status VARCHAR(50) NULL,

    -- Comentário operacional livre do BP.
    bp_comment TEXT NULL,


    -- ========================================================
    -- VEÍCULO / FATURAMENTO
    -- ========================================================

    chassis_serial_number VARCHAR(17) NOT NULL,

    material VARCHAR(12) NULL,

    description VARCHAR(50) NULL,

    invoice_number VARCHAR(9) NOT NULL,

    issuance_date DATE NOT NULL,

    sold_to_party_cnpj CHAR(14) NULL,

    sold_to_party_name VARCHAR(100) NULL,


    -- ========================================================
    -- ENRIQUECIMENTO DEALER
    -- ========================================================
    -- Origem:
    -- bronze.mapping_dealer_expansion
    --
    -- Chave:
    -- ship_to_party_code -> sap_code
    --
    -- Atualizado por:
    -- sp_gold_z17_demo_enrich_dealer
    -- ========================================================

    dealer_group VARCHAR(100) NULL,

    brand_dealer VARCHAR(100) NULL,


    -- ========================================================
    -- CICLO DEMO
    -- ========================================================

    -- Início do ciclo DEMO.
    demo_started_at DATETIME NOT NULL,

    -- Primeiro aviso.
    -- Regra atual: faturamento DEMO + 20 dias.
    warning_date DATE NOT NULL,

    -- Momento em que a notificação de WARNING foi enviada.
    warning_sent_at DATETIME NULL,

    -- Data de vencimento.
    -- Regra atual: faturamento DEMO + 30 dias.
    due_date DATE NOT NULL,

    -- Momento em que a notificação de OVERDUE foi enviada.
    overdue_sent_at DATETIME NULL,

    -- Momento em que o ciclo foi encerrado.
    -- NULL enquanto permanecer aberto.
    closed_at DATETIME NULL,

    -- NF responsável por iniciar o ciclo DEMO.
    -- Permanece igual para todos os eventos do ciclo.
    demo_origin_invoice_number VARCHAR(9) NOT NULL,

    -- Momento em que a notificação da NF DEMO foi enviada.
    demo_invoice_sent_at DATETIME NULL,

    -- Ordem cronológica dentro do ciclo:
    -- 1  = faturamento DEMO original
    -- 2+ = movimentações posteriores
    event_sequence INT UNSIGNED NOT NULL,

    -- Identidade do ciclo DEMO.
    demo_cycle_key VARCHAR(100) DEFAULT NULL,

    -- Identidade do documento/evento.
    document_key VARCHAR(100) DEFAULT NULL,


    -- ========================================================
    -- AUDITORIA DO DEMO HISTORY
    -- ========================================================

    -- Primeira vez que o evento foi identificado.
    first_seen_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Última vez que o evento foi encontrado pela sincronização.
    last_seen_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Momento em que o registro entrou no histórico.
    created_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Última alteração realizada no registro.
    updated_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,


    -- ========================================================
    -- SNAPSHOT DA MOVIMENTAÇÃO
    -- ========================================================
    -- Dados provenientes principalmente da:
    -- bp_datalake.silver_zsdbil17_outbound_movements
    -- ========================================================

    ship_to_party_code VARCHAR(20) NULL,

    ship_to_party_cnpj CHAR(14) NULL,

    ship_to_party_name VARCHAR(100) NULL,

    ship_to_party_state CHAR(2) NULL,

    payment_condition VARCHAR(10) NULL,

    -- Atualmente pode ser mantido NULL quando inexistente
    -- na fonte utilizada pela sincronização.
    payment_condition_description_dim VARCHAR(255) NULL,

    ncm CHAR(10) NULL,

    cfop CHAR(10) NULL,

    -- Classificação do CFOP para movimentação de veículo:
    -- Yes
    -- No
    -- Unknown
    cfop_car VARCHAR(10) NULL,

    -- Status calculado da chave de acesso:
    -- VALID
    -- CANCELLED
    -- MISSING
    -- INVALID_FORMAT
    -- INVALID_CHECK_DIGIT
    access_key_status VARCHAR(30) NULL,

    plant_code VARCHAR(10) NULL,

    -- Mantido no contrato para enriquecimento quando disponível.
    plant_description VARCHAR(100) NULL,

    sap_document VARCHAR(10) NULL,

    billing_number_vf01 VARCHAR(10) NULL,

    -- Mantido no contrato para enriquecimento quando disponível.
    origem_chassi VARCHAR(20) NULL,

    source_file VARCHAR(255) NULL,

    -- Data de carga existente na fonte.
    dt_carga DATETIME NULL,


    -- ========================================================
    -- CAMPOS TÉCNICOS / COMPLEMENTARES
    -- ========================================================

    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

    division VARCHAR(5) NULL,

    sold_to_party_code VARCHAR(20) NULL,

    sold_to_party_state CHAR(2) NULL,

    -- A chave de acesso pode ser NULL e não é utilizada
    -- isoladamente para validar a existência de um DEMO.
    chave_de_acesso CHAR(44) NULL,

    -- Descrição original recebida do SAP.
    division_description TEXT NULL,


    -- ========================================================
    -- CHAVES E ÍNDICES
    -- ========================================================

    PRIMARY KEY (id),


    -- --------------------------------------------------------
    -- IDENTIDADE DO EVENTO
    -- --------------------------------------------------------
    -- Evita que o mesmo evento seja inserido novamente durante
    -- uma reexecução da sincronização.
    --
    -- event_type não participa da identidade porque pode ser
    -- reclassificado posteriormente.
    -- --------------------------------------------------------

    UNIQUE KEY uk_demo_invoice (
        chassis_serial_number,
        demo_origin_invoice_number,
        invoice_number
    ),


    -- --------------------------------------------------------
    -- SEQUÊNCIA DO CICLO
    -- --------------------------------------------------------
    -- Não é UNIQUE propositalmente.
    --
    -- A sequência pode ser recalculada caso uma movimentação
    -- histórica intermediária seja localizada posteriormente.
    -- --------------------------------------------------------

    KEY idx_demo_sequence (
        chassis_serial_number,
        demo_origin_invoice_number,
        event_sequence
    ),


    -- --------------------------------------------------------
    -- CONSULTAS OPERACIONAIS
    -- --------------------------------------------------------
    -- Utilizado principalmente para ciclos em aberto,
    -- WARNING e OVERDUE.
    -- --------------------------------------------------------

    KEY idx_demo_status_due (
        demo_status,
        due_date
    ),


    -- --------------------------------------------------------
    -- CONSULTA POR NF
    -- --------------------------------------------------------

    KEY idx_demo_invoice (
        invoice_number
    ),


    -- --------------------------------------------------------
    -- CONSULTAS HISTÓRICAS POR DATA
    -- --------------------------------------------------------

    KEY idx_demo_issuance_date (
        issuance_date
    )

)
ENGINE = InnoDB
COMMENT = 'Histórico independente dos ciclos DEMO e movimentações posteriores dos chassis';
