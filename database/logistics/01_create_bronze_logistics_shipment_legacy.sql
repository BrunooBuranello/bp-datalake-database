-- ============================================================
-- TABELA: bp_datalake.bronze_logistics_shipment_legacy
-- CAMADA: Bronze (carga única da planilha do time de Logística)
--
-- ORIGEM:
-- Planilha "PERFORMANCE GERAL NOVO.xlsx" do time de Logística
-- (pasta de rede). Uma aba por planta e período, todas com o
-- mesmo layout (34 a 39 colunas):
--   CARIACICA 1..4, CAMAÇARI / CAMAÇARI 2026 / 2026 2 / 3,
--   ARAQUARI 1 / 2 / 2026 / 2026 2, SUAPE 1 / 2 / 2026.
-- A aba "PERFORMANCE GERAL" é a soma dessas abas (mesmo número
-- de linhas) e NÃO é carregada, para não duplicar embarques.
-- Abas de rascunho (Planilha1, Planilha2, CONSULTA) ficam fora.
--
-- OBJETIVO:
-- Guardar o histórico de embarques de veículos (coleta, trânsito
-- e entrega por transportadora) que hoje só existe na planilha,
-- para o app logistics mostrar a base e os indicadores e para a
-- planilha deixar de ser a fonte depois da data de corte.
--
-- ESTRATÉGIA:
-- - Carga ÚNICA (APPEND) pelo comando
--   `manage.py load_logistics_legacy --file ... --user ...`.
--   O comando recusa um arquivo que já foi carregado
--   (mesmo source_file), para não gravar o histórico em dobro.
-- - Fiel à origem: todas as colunas da planilha em TEXT, com o
--   valor como o Excel entrega (data vira "AAAA-MM-DD HH:MM:SS",
--   número de série do Excel continua número, texto continua
--   texto). Nenhum valor é corrigido aqui; a limpeza (datas em 3
--   formatos, 26 grafias de modalidade, "FABRICA"/"FÁBRICA"...)
--   fica para a Silver.
-- - Nomes das colunas = cabeçalho da planilha em snake_case, sem
--   corrigir o sentido. Atenção: a coluna "CNPJ" da planilha traz
--   a planta emissora ("BYD - ES", "BYD - BA"...), não um CNPJ.
-- - Uma linha = um chassi embarcado. O mesmo chassi pode aparecer
--   mais de uma vez (retorno / reembarque): duplicidade permitida.
--
-- CONTROLE DA CARGA (não vem da planilha):
-- - source_file, source_sheet, source_row: rastreio até a célula;
-- - pick_up_date_sort: a coleta como DATE, só para ordenar e
--   filtrar por período na tela. A coluna original continua em
--   pick_up_date (texto). NULL quando a planilha não tem data
--   reconhecível. É a única coluna derivada desta tabela.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_logistics_shipment_legacy (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- RESPONSÁVEL E ORIGEM DO VEÍCULO
    -- ========================================================

    pic TEXT NULL
        COMMENT 'PIC: pessoa da Logística responsável pelo embarque',
    cnpj TEXT NULL
        COMMENT 'CNPJ da planilha: na prática a planta emissora (BYD - ES / BA / SC / PE)',

    -- ========================================================
    -- VEÍCULO E NF
    -- ========================================================

    car_model TEXT NULL,
    color TEXT NULL,
    vin_number TEXT NULL
        COMMENT 'Chassi (VIN)',
    invoice_number TEXT NULL
        COMMENT 'NF de venda; às vezes texto (ex.: CRLV) na origem',
    nf_received_from_back_office_team TEXT NULL
        COMMENT 'NF RECEIVED FROM BACK-OFFICE TEAM: data em que a NF chegou do back-office',
    sales_modality TEXT NULL
        COMMENT 'Revenda, Venda Direta, Test Drive... (texto livre na origem)',

    -- ========================================================
    -- SOLICITAÇÃO E COLETA
    -- ========================================================

    hour TEXT NULL,
    requesting_date TEXT NULL,
    carrier TEXT NULL
        COMMENT 'Transportadora',
    weekday_pick_up_date TEXT NULL,
    pick_up_date TEXT NULL
        COMMENT 'Data de coleta como veio da planilha',
    aging TEXT NULL,
    warehouse TEXT NULL
        COMMENT 'Pátio / armazém de saída',

    -- ========================================================
    -- DESTINO
    -- ========================================================

    dealer TEXT NULL,
    place_of_delivery TEXT NULL,
    city_of_delivery TEXT NULL,
    state_of_delivery TEXT NULL,
    zone TEXT NULL,

    -- ========================================================
    -- PRAZOS E ENTREGA
    -- ========================================================

    transit_time TEXT NULL
        COMMENT 'Prazo planejado em dias',
    weekday_eta TEXT NULL,
    eta TEXT NULL
        COMMENT 'Previsão de entrega',
    eta_2 TEXT NULL,
    rta TEXT NULL
        COMMENT 'Data real de entrega',
    pick_up_date_carrier TEXT NULL,
    eta_carrier TEXT NULL,
    day_eta_carrier TEXT NULL,
    transit_time2 TEXT NULL,
    transit_time3 TEXT NULL,
    late_delivery TEXT NULL
        COMMENT 'EM DIA / ATRASADO (calculado na planilha)',
    status TEXT NULL
        COMMENT 'AGUARDANDO EMBARQUE / EM TRÂNSITO / ENTREGUE / RETORNO',

    -- ========================================================
    -- MOTIVOS E OCORRÊNCIAS
    -- ========================================================

    boarding_information TEXT NULL,
    boarding_information_2 TEXT NULL,
    em_programacao_1a_x TEXT NULL
        COMMENT 'EM PROGRAMAÇÃO (1ªX)',
    contador_de_programacao TEXT NULL,
    observacoes_e_ocorrencias TEXT NULL,
    ocorrencias_de_transporte TEXT NULL,
    justification_for_delay TEXT NULL,

    -- ========================================================
    -- CONTROLE DA CARGA (não vem da planilha)
    -- ========================================================

    pick_up_date_sort DATE NULL
        COMMENT 'Coleta como DATE, só para ordenar/filtrar; original em pick_up_date',
    source_file TEXT NULL,
    source_sheet TEXT NULL,
    source_row INT NULL
        COMMENT 'Linha da aba no Excel (1 = cabeçalho)',

    -- ========================================================
    -- AUDITORIA DA INGESTÃO
    -- ========================================================

    dt_carga TEXT NULL,
    usuario TEXT NULL,

    -- ========================================================
    -- ÍNDICES (NÃO UNIQUE: chassi repetido faz parte da origem)
    -- ========================================================

    PRIMARY KEY (id),
    INDEX idx_bronze_logistics_shipment_legacy_vin (vin_number(17)),
    INDEX idx_bronze_logistics_shipment_legacy_invoice (invoice_number(20)),
    INDEX idx_bronze_logistics_shipment_legacy_pickup (pick_up_date_sort),
    INDEX idx_bronze_logistics_shipment_legacy_source (source_file(100))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'Histórico de embarques da planilha PERFORMANCE GERAL da Logística (carga única, fiel à origem)';
