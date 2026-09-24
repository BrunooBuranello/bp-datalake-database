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
-- A Silver é utilizada porque preserva o histórico das
-- movimentações do chassi antes da consolidação realizada
-- na Gold principal.
--
-- Cada nova movimentação relevante do mesmo chassi gera
-- um novo evento, preservando a fotografia daquele momento.
--
-- Exemplo:
-- event_sequence = 1 -> faturamento DEMO original
-- event_sequence = 2 -> primeira movimentação posterior
-- event_sequence = 3 -> próxima movimentação
-- event_sequence = N -> demais movimentações
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
    -- CONTROLE DO HISTÓRICO
    -- ========================================================

    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

    demo_cycle_key VARCHAR(100) DEFAULT NULL,
    document_key VARCHAR(100) DEFAULT NULL,

    demo_invoice_sent_at DATETIME NULL,

    -- NF responsável por iniciar o ciclo DEMO.
    -- Permanece igual para todos os eventos daquele ciclo.
    demo_origin_invoice_number VARCHAR(9) NOT NULL,

    -- Ordem cronológica dos eventos dentro do ciclo DEMO.
    --
    -- 1 = faturamento DEMO original
    -- 2+ = movimentações posteriores
    event_sequence INT UNSIGNED NOT NULL,

    -- Tipo do evento.
    --
    -- Valores atualmente utilizados:
    -- DEMO
    -- REINVOICE
    -- CANCELLATION
    event_type VARCHAR(30) NOT NULL,

    -- Situação atual do ciclo DEMO.
    --
    -- OPEN
    -- WARNING
    -- OVERDUE
    -- CLOSED
    demo_status VARCHAR(20) NOT NULL,

    -- Início do ciclo DEMO.
    demo_started_at DATETIME NOT NULL,

    -- Data para primeiro aviso.
    -- Regra atual: faturamento DEMO + 20 dias.
    warning_date DATE NOT NULL,

    -- Data de vencimento.
    -- Regra atual: faturamento DEMO + 30 dias.
    due_date DATE NOT NULL,

    -- Momento em que o ciclo foi encerrado.
    -- NULL enquanto permanecer aberto.
    closed_at DATETIME NULL,


    -- ========================================================
    -- AUDITORIA DO DEMO HISTORY
    -- ========================================================

    -- Primeira vez que o evento foi identificado.
    first_seen_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Última vez que o evento foi encontrado pela sincronização.
    last_seen_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Momento em que o registro entrou no Demo History.
    created_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    -- Última atualização realizada no registro.
    updated_at DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,


    -- ========================================================
    -- SNAPSHOT DA SILVER
    -- ========================================================
    -- Fotografia da movimentação existente em:
    --
    -- bp_datalake.silver_zsdbil17_outbound_movements
    -- ========================================================

    -- Pode ser NULL.
    -- A chave de acesso não é utilizada isoladamente
    -- para validar a existência de um DEMO.
    chave_de_acesso CHAR(44) NULL,

    chassis_serial_number VARCHAR(17) NOT NULL,

    division VARCHAR(5) NULL,

    -- Descrição original recebida do SAP.
    division_description TEXT NULL,

    -- Descrição enriquecida pelo pipeline.
    --
    -- Prioridade:
    -- 1. Division
    -- 2. CFOP como fallback
    -- 3. UNKNOWN
    division_description_enriched VARCHAR(100) NULL,

    invoice_number VARCHAR(9) NOT NULL,

    issuance_date DATE NOT NULL,

    material VARCHAR(12) NULL,

    description VARCHAR(50) NULL,

    sold_to_party_code VARCHAR(20) NULL,

    sold_to_party_cnpj CHAR(14) NULL,

    sold_to_party_name VARCHAR(100) NULL,

    sold_to_party_state CHAR(2) NULL,

    ship_to_party_code VARCHAR(20) NULL,

    ship_to_party_cnpj CHAR(14) NULL,

    ship_to_party_name VARCHAR(100) NULL,

    ship_to_party_state CHAR(2) NULL,

    payment_condition VARCHAR(10) NULL,

    -- Atualmente não existe na Silver.
    -- Mantido no contrato para possível enriquecimento futuro.
    payment_condition_description_dim VARCHAR(255) NULL,

    ncm CHAR(10) NULL,

    cfop CHAR(10) NULL,

    -- Classificação do CFOP para movimentação de veículo.
    --
    -- Yes
    -- No
    -- Unknown
    cfop_car VARCHAR(10) NULL,

    -- Status calculado da chave de acesso na Silver.
    --
    -- VALID
    -- CANCELLED
    -- MISSING
    -- INVALID_FORMAT
    -- INVALID_CHECK_DIGIT
    --
    -- Campo informativo/auditável.
    access_key_status VARCHAR(30) NULL,

    plant_code VARCHAR(10) NULL,

    -- Atualmente não existe na Silver.
    -- Mantido no contrato para possível enriquecimento futuro.
    plant_description VARCHAR(100) NULL,

    sap_document VARCHAR(10) NULL,

    billing_number_vf01 VARCHAR(10) NULL,

    -- Atualmente não existe na Silver.
    -- Mantido no contrato para possível enriquecimento futuro.
    origem_chassi VARCHAR(20) NULL,

    source_file VARCHAR(255) NULL,

    -- Data de carga existente na Silver.
    dt_carga DATETIME NULL,


    -- ========================================================
    -- CHAVES E ÍNDICES
    -- ========================================================

    PRIMARY KEY (id),


    -- --------------------------------------------------------
    -- Identidade do evento.
    --
    -- Um mesmo evento não pode ser inserido novamente
    -- durante uma reexecução da procedure.
    --
    -- O event_type não participa da identidade porque pode
    -- ser reclassificado posteriormente.
    -- --------------------------------------------------------

    UNIQUE KEY uk_demo_invoice (
        chassis_serial_number,
        demo_origin_invoice_number,
        invoice_number
    ),


    -- --------------------------------------------------------
    -- Consulta da sequência de eventos do ciclo.
    --
    -- NÃO é UNIQUE propositalmente.
    -- A sequência pode ser recalculada caso uma movimentação
    -- histórica intermediária seja encontrada posteriormente.
    -- --------------------------------------------------------

    KEY idx_demo_sequence (
        chassis_serial_number,
        demo_origin_invoice_number,
        event_sequence
    ),


    -- --------------------------------------------------------
    -- Consultas operacionais por status e vencimento.
    --
    -- Utilizado principalmente para:
    -- aviso de 20 dias
    -- vencimento de 30 dias
    -- ciclos ainda em aberto
    -- --------------------------------------------------------

    KEY idx_demo_status_due (
        demo_status,
        due_date
    ),


    -- --------------------------------------------------------
    -- Consulta por número da NF.
    -- --------------------------------------------------------

    KEY idx_demo_invoice (
        invoice_number
    ),


    -- --------------------------------------------------------
    -- Consultas históricas por data de faturamento.
    -- --------------------------------------------------------

    KEY idx_demo_issuance_date (
        issuance_date
    )


)
ENGINE = InnoDB
COMMENT = 'Histórico independente dos ciclos DEMO e movimentações posteriores dos chassis';
