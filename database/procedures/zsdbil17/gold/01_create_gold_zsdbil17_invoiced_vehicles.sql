/*
============================================================
ZSDBIL17 - GOLD
============================================================

Arquivo:
01_create_gold_zsdbil17_invoiced_vehicles.sql

Objetivo:
Criar a nova tabela Gold de faturamento de veículos.

Tabela temporária de homologação:
    bp_datalake.gold_zsdbil17_faturamento_v2

A tabela oficial atualmente utilizada em produção:
    bp_datalake.gold_zsdbil17_faturamento

NÃO deve ser alterada por este script.

============================================================
RESPONSABILIDADE DA GOLD
============================================================

A Gold representa o estado atual do faturamento dos veículos.

Regra de granularidade:

    1 chassi = 1 linha

Quando um mesmo chassi possuir mais de um faturamento na Silver,
a carga Gold deverá selecionar o registro mais recente utilizando:

    ROW_NUMBER() OVER (
        PARTITION BY chassis_serial_number
        ORDER BY
            issuance_date DESC,
            invoice_number DESC,
            id DESC
    )

IMPORTANTE:

A seleção e classificação dos registros NÃO pertence a este DDL.

As regras serão implementadas posteriormente na procedure de carga:

    02_sp_gold_z17_load_base.sql

A Gold deverá trabalhar sobre classificações já realizadas na Silver,
como:

    cfop_car
    source_status
    access_key_status

============================================================
ESTRATÉGIA DE MIGRAÇÃO
============================================================

Durante homologação:

    gold_zsdbil17_faturamento
        = produção atual

    gold_zsdbil17_faturamento_v2
        = nova arquitetura

Após validação, será realizado o cutover por RENAME TABLE.

A tabela antiga será preservada inicialmente como:

    gold_zsdbil17_faturamento_legacy

============================================================
*/

CREATE TABLE bp_datalake.gold_zsdbil17_faturamento_v2 (

    /*
    ============================================================
    RASTREABILIDADE
    ============================================================
    */

    id_bronze BIGINT NOT NULL,


    /*
    ============================================================
    FATURAMENTO / VEÍCULO
    ============================================================
    */

    chassis_serial_number VARCHAR(17) NOT NULL,

    invoice_number VARCHAR(9) NOT NULL,

    issuance_date DATE NOT NULL,

    material VARCHAR(12) NULL,

    description VARCHAR(50) NULL,

    descricao_do_produto VARCHAR(255) NULL,

    descricao_da_cor VARCHAR(50) NULL,

    manufacturing_year SMALLINT NULL,

    model_year SMALLINT NULL,

    total_amount DECIMAL(15,2) NULL,


    /*
    ============================================================
    DEALER / REDE
    ============================================================

    Campos enriquecidos posteriormente na Gold.
    ============================================================
    */

    store_name_crm VARCHAR(100) NULL,

    dealer_group VARCHAR(100) NULL,

    brand_dealer VARCHAR(100) NULL,


    /*
    ============================================================
    EMPRESA / CLIENTES
    ============================================================
    */

    byd_cnpj_number CHAR(14) NULL,

    sold_to_party_code VARCHAR(20) NULL,

    sold_to_party_cnpj CHAR(14) NULL,

    sold_to_party_name VARCHAR(100) NULL,

    sold_to_party_state CHAR(2) NULL,

    ship_to_party_code VARCHAR(20) NULL,

    ship_to_party_cnpj CHAR(14) NULL,

    ship_to_party_name VARCHAR(100) NULL,

    ship_to_party_state CHAR(2) NULL,


    /*
    ============================================================
    CONDIÇÃO DE PAGAMENTO
    ============================================================
    */

    payment_condition VARCHAR(10) NULL,


    /*
    ============================================================
    DADOS FISCAIS
    ============================================================
    */

    chave_de_acesso CHAR(44) NOT NULL,

    ncm CHAR(10) NULL,

    cfop CHAR(10) NULL,


    /*
    ============================================================
    PLANTA / ORGANIZAÇÃO SAP
    ============================================================
    */

    plant_code VARCHAR(10) NULL,

    /*
    Enriquecimento por dimensão de planta.
    */
    plant_description VARCHAR(100) NULL,

    company_code VARCHAR(12) NULL,

    sales_order_type VARCHAR(6) NULL,

    division VARCHAR(5) NULL,

    /*
    Classificação comercial enriquecida na Gold.

    Fonte principal:
        dim_sales_order_type

    Fallback:
        dim_cfop_sales_type
    */
    division_description VARCHAR(100) NULL,


    /*
    ============================================================
    DOCUMENTOS SAP / PEDIDO
    ============================================================
    */

    sap_document VARCHAR(10) NULL,

    sales_order_number VARCHAR(10) NULL,


    /*
    ============================================================
    ENRIQUECIMENTO DE PAGAMENTO
    ============================================================
    */

    payment_condition_description_dim VARCHAR(255) NULL,


    /*
    ============================================================
    CLASSIFICAÇÃO DO VEÍCULO
    ============================================================
    */

    origem_chassi VARCHAR(20) NULL,

    invoice_series VARCHAR(8) NULL,


    /*
    ============================================================
    DADOS TÉCNICOS DO VEÍCULO
    ============================================================
    */

    no_do_motor VARCHAR(20) NULL,

    codigo_da_cor VARCHAR(10) NULL,

    potencia_motor SMALLINT NULL,

    cap_trac_max DECIMAL(6,3) NULL,

    cilindradas_cc SMALLINT NULL,

    distancia_entre_eixo SMALLINT NULL,

    peso_liquido_ton DECIMAL(6,3) NULL,

    peso_bruto_ton DECIMAL(6,3) NULL,

    tipo_de_veiculo VARCHAR(20) NULL,

    especie_do_veiculo VARCHAR(20) NULL,

    tipo_do_combustivel CHAR(2) NULL,

    tipo_de_pintura VARCHAR(10) NULL,

    condicao_do_veiculo CHAR(1) NULL,

    cap_ocup_max TINYINT NULL,

    vin_condition VARCHAR(10) NULL,

    code_brand_mode VARCHAR(10) NULL,

    item_category VARCHAR(9) NULL,


    /*
    ============================================================
    DIRECT SALES
    ============================================================

    Enriquecimentos obtidos posteriormente a partir
    da base de Direct Sales.
    ============================================================
    */

    order_no VARCHAR(100) NULL,

    order_car_no VARCHAR(100) NULL,

    order_status VARCHAR(100) NULL,


    /*
    ============================================================
    AUDITORIA
    ============================================================
    */

    usuario VARCHAR(100) NOT NULL,

    source_file VARCHAR(255) NULL,

    dt_carga_silver DATETIME NULL,

    dt_carga_gold DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    id_execucao BIGINT NOT NULL,


    /*
    ============================================================
    CHAVE PRIMÁRIA
    ============================================================

    Regra da Gold:

        1 chassi = 1 linha
    ============================================================
    */

    PRIMARY KEY (chassis_serial_number),


    /*
    ============================================================
    ÍNDICES
    ============================================================
    */

    INDEX idx_gold_invoice_number (
        invoice_number
    ),

    INDEX idx_gold_material (
        material
    ),

    INDEX idx_gold_chave_de_acesso (
        chave_de_acesso
    )

) ENGINE = InnoDB;

/*
============================================================
RESULTADO ESPERADO
============================================================

Após execução deste arquivo deverão coexistir:

    bp_datalake.gold_zsdbil17_faturamento
        -> Gold atualmente utilizada em produção

    bp_datalake.gold_zsdbil17_faturamento_v2
        -> Nova Gold em homologação


Nenhum dado é carregado por este arquivo.

O próximo arquivo será responsável pela carga:

    02_sp_gold_z17_load_base.sql

============================================================
*/
