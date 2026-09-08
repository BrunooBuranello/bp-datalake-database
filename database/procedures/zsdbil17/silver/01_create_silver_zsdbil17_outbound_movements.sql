CREATE TABLE IF NOT EXISTS silver_zsdbil17_outbound_movements (

    /*
    =========================================================
    01. RASTREABILIDADE DA ORIGEM
    =========================================================
    */

    id_bronze BIGINT NOT NULL
        COMMENT 'ID técnico da linha de origem na Bronze; usado apenas para rastreabilidade',

    reconciliation_hash BINARY(16) NULL
        COMMENT 'Hash de reconciliação do documento SAP herdado da Bronze',


    /*
    =========================================================
    02. DOCUMENTO SAP / ORDEM DE VENDA
    =========================================================
    */

    sap_document VARCHAR(50) NULL
        COMMENT 'Número do documento SAP',

    company_code TEXT NULL
        COMMENT 'Código da empresa no SAP',

    plant_code TEXT NULL
        COMMENT 'Código do centro/planta no SAP',

    sales_order_number TEXT NULL
        COMMENT 'Número da ordem de venda',

    sales_order_type TEXT NULL
        COMMENT 'Tipo da ordem de venda',

    item_category TEXT NULL
        COMMENT 'Categoria do item da ordem de venda; origem Bronze: item_categoy',

    so_item TEXT NULL
        COMMENT 'Número do item da ordem de venda',

    created_by_so TEXT NULL
        COMMENT 'Usuário ou origem responsável pela criação da ordem de venda',

    distribution_channel TEXT NULL
        COMMENT 'Canal de distribuição',

    division TEXT NULL
        COMMENT 'Código da divisão comercial',

    division_description TEXT NULL
        COMMENT 'Descrição da divisão comercial',

    customer_reference TEXT NULL
        COMMENT 'Referência do cliente associada ao documento',


    /*
    =========================================================
    03. ENTREGA / FATURAMENTO / DOCUMENTO FISCAL
    =========================================================
    */

    delivery_note_number_picking TEXT NULL
        COMMENT 'Número da entrega utilizado no processo de picking',

    billing_number_vf01 TEXT NULL
        COMMENT 'Número do documento de faturamento gerado no VF01',

    goods_issue_document TEXT NULL
        COMMENT 'Número do documento de saída de mercadoria',

    invoice_number VARCHAR(50) NULL
        COMMENT 'Número da nota fiscal',

    invoice_series TEXT NULL
        COMMENT 'Série da nota fiscal',

    issuance_date DATE NULL
        COMMENT 'Data de emissão do documento fiscal',

    status_doc TEXT NULL
        COMMENT 'Status do documento informado pela ZSDBIL17',

    estornado TEXT NULL
        COMMENT 'Indicador de estorno informado pela ZSDBIL17',

    chave_de_acesso VARCHAR(100) NULL
        COMMENT 'Chave de acesso da NF-e; VARCHAR para permitir estados como 00 antes da classificação',

    nf_reference TEXT NULL
        COMMENT 'Referência de nota fiscal informada pelo SAP',


    /*
    =========================================================
    04. MATERIAL / IDENTIFICAÇÃO DO VEÍCULO
    =========================================================
    */

    material TEXT NULL
        COMMENT 'Código do material',

    ncm TEXT NULL
        COMMENT 'Código NCM conforme recebido do SAP',

    origin TEXT NULL
        COMMENT 'Código de origem do material',

    utiliz_material TEXT NULL
        COMMENT 'Código de utilização do material',

    description TEXT NULL
        COMMENT 'Descrição do material ou item',

    chassis_serial_number VARCHAR(100) NULL
        COMMENT 'Número do chassi/VIN principal do registro',

    cfop TEXT NULL
        COMMENT 'Código CFOP conforme recebido do SAP',

    grpmercads TEXT NULL
        COMMENT 'Grupo de mercadorias informado pelo SAP',

    tipo_de_operacao TEXT NULL
        COMMENT 'Código do tipo de operação informado pelo SAP',


    /*
    =========================================================
    05. PARCEIROS COMERCIAIS
    =========================================================
    */

    sold_to_party_code TEXT NULL
        COMMENT 'Código do cliente Sold-To',

    sold_to_party_cnpj TEXT NULL
        COMMENT 'CNPJ do cliente Sold-To',

    sold_to_party_name TEXT NULL
        COMMENT 'Nome do cliente Sold-To',

    sold_to_party_state TEXT NULL
        COMMENT 'UF do cliente Sold-To',

    ship_to_party_code TEXT NULL
        COMMENT 'Código do cliente Ship-To',

    ship_to_party_cnpj TEXT NULL
        COMMENT 'CNPJ do cliente Ship-To',

    ship_to_party_name TEXT NULL
        COMMENT 'Nome do cliente Ship-To',

    ship_to_party_state TEXT NULL
        COMMENT 'UF do cliente Ship-To',

    transportation_code TEXT NULL
        COMMENT 'Código da transportadora',

    transportation_cnpj TEXT NULL
        COMMENT 'CNPJ da transportadora',

    transportation_name TEXT NULL
        COMMENT 'Nome da transportadora',

    transportation_state TEXT NULL
        COMMENT 'UF da transportadora',


    /*
    =========================================================
    06. PAGAMENTO
    =========================================================
    */

    payment_condition TEXT NULL
        COMMENT 'Código da condição de pagamento',

    payment_condition_description TEXT NULL
        COMMENT 'Descrição da condição de pagamento',

    payment_method TEXT NULL
        COMMENT 'Código do método de pagamento',

    payment_method_description TEXT NULL
        COMMENT 'Descrição do método de pagamento; origem Bronze: payment_method_descripition',


    /*
    =========================================================
    07. QUANTIDADE / PREÇOS / VALORES
    =========================================================
    */

    qty DECIMAL(18,3) NULL
        COMMENT 'Quantidade do item',

    total_amount DECIMAL(18,2) NULL
        COMMENT 'Valor total do registro',

    total_invoice_net_price DECIMAL(18,2) NULL
        COMMENT 'Preço líquido total da nota',

    item_product_amount DECIMAL(18,2) NULL
        COMMENT 'Valor do produto no item',

    item_total_net_price DECIMAL(18,2) NULL
        COMMENT 'Preço líquido total do item',

    msrp_pr00 DECIMAL(18,2) NULL
        COMMENT 'Preço de referência da condição PR00',

    istf_price_fixed DECIMAL(18,2) NULL
        COMMENT 'Valor da condição de preço ISTF',


    /*
    =========================================================
    08. TRIBUTOS ICMS / IPI / PIS / COFINS
    =========================================================
    */

    cb_icms DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do ICMS',

    icms_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de ICMS',

    icms_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de ICMS',

    cb_icms_st DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do ICMS ST',

    st_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de ICMS ST',

    icms_st_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de ICMS ST',

    cb_ipi DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do IPI',

    ipi_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de IPI',

    ipi_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de IPI',

    cb_pis DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do PIS',

    pis_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de PIS',

    pis_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de PIS',

    cb_cofins DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do COFINS',

    cofins_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de COFINS',

    cofins_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de COFINS',

    iva TEXT NULL
        COMMENT 'Código IVA informado pelo SAP',

    dir_fiscal_icms TEXT NULL
        COMMENT 'Direito ou classificação fiscal de ICMS',

    dir_fiscal_ipi TEXT NULL
        COMMENT 'Direito ou classificação fiscal de IPI',

    dir_fiscal_iss TEXT NULL
        COMMENT 'Direito ou classificação fiscal de ISS',

    dir_fiscal_cofins TEXT NULL
        COMMENT 'Direito ou classificação fiscal de COFINS',

    dir_fiscal_pis TEXT NULL
        COMMENT 'Direito ou classificação fiscal de PIS',


    /*
    =========================================================
    09. FCP / DIFAL / SUBSTITUIÇÃO TRIBUTÁRIA
    =========================================================
    */

    vlr_fcp_subst_icms DECIMAL(18,2) NULL
        COMMENT 'Valor de FCP relacionado à substituição de ICMS',

    bc_fcp DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do FCP',

    fcp_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de FCP',

    fcp_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de FCP',

    bc_difal DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do DIFAL',

    difal_percentual DECIMAL(18,9) NULL
        COMMENT 'Percentual de DIFAL',

    difal DECIMAL(18,2) NULL
        COMMENT 'Valor de DIFAL',

    mva_percentual_ists DECIMAL(18,9) NULL
        COMMENT 'Percentual de MVA da condição ISTS',

    bc_fcp_subst_icms DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo do FCP de substituição de ICMS',

    aliq_fcp_subst_icms DECIMAL(18,9) NULL
        COMMENT 'Alíquota de FCP de substituição de ICMS',


    /*
    =========================================================
    10. COMISSÕES / DESCONTOS
    =========================================================
    */

    commission_percentual_zcom DECIMAL(18,9) NULL
        COMMENT 'Percentual de comissão da condição ZCOM',

    commission_amount DECIMAL(18,2) NULL
        COMMENT 'Valor de comissão',

    discont_percentual_ra01 DECIMAL(18,9) NULL
        COMMENT 'Percentual de desconto da condição RA01',

    sharing_icms_percentual_zbx9 DECIMAL(18,9) NULL
        COMMENT 'Percentual de compartilhamento de ICMS da condição ZBX9',

    discount_amount_ra01 DECIMAL(18,2) NULL
        COMMENT 'Valor de desconto da condição RA01',

    discount_of_pcd_zdvp DECIMAL(18,2) NULL
        COMMENT 'Valor de desconto PCD da condição ZDVP',

    discount_value_amount_rb00 DECIMAL(18,2) NULL
        COMMENT 'Valor de desconto da condição RB00',

    pcd_sales_limit_zlvp DECIMAL(18,2) NULL
        COMMENT 'Valor de limite de venda PCD da condição ZLVP',


    /*
    =========================================================
    11. DEVOLUÇÃO DE VENDA
    =========================================================
    */

    dev_venda_sap_doc TEXT NULL
        COMMENT 'Documento SAP relacionado à devolução de venda',

    dev_venda_sales_order TEXT NULL
        COMMENT 'Ordem de venda relacionada à devolução',

    dev_venda_so_item TEXT NULL
        COMMENT 'Item da ordem relacionado à devolução',

    dev_venda_material_code TEXT NULL
        COMMENT 'Código do material relacionado à devolução',

    dev_venda_description TEXT NULL
        COMMENT 'Descrição do item relacionado à devolução',

    dev_venda_chassis TEXT NULL
        COMMENT 'Chassi relacionado à devolução',

    dev_venda_dn_picking TEXT NULL
        COMMENT 'Documento de entrega/picking relacionado à devolução',

    dev_venda_billing_number_vf01 TEXT NULL
        COMMENT 'Documento de faturamento VF01 relacionado à devolução',

    dev_venda_invoice_number TEXT NULL
        COMMENT 'Número da nota fiscal relacionada à devolução',

    dev_venda_issuance_date DATE NULL
        COMMENT 'Data de emissão da devolução',

    dev_venda_status_doc TEXT NULL
        COMMENT 'Status do documento de devolução',

    dev_venda_chave_de_acesso TEXT NULL
        COMMENT 'Chave de acesso da NF-e relacionada à devolução',


    /*
    =========================================================
    12. IMPORTAÇÃO / DI
    =========================================================
    */

    n_di TEXT NULL
        COMMENT 'Número da Declaração de Importação',

    data_da_di DATE NULL
        COMMENT 'Data da Declaração de Importação',


    /*
    =========================================================
    13. DADOS TÉCNICOS DO VEÍCULO
    =========================================================
    */

    descricao_do_produto TEXT NULL
        COMMENT 'Descrição técnica/comercial do produto',

    chassi_do_veiculo TEXT NULL
        COMMENT 'Chassi do veículo informado no bloco técnico do relatório',

    no_de_serie TEXT NULL
        COMMENT 'Número de série do veículo ou componente',

    no_do_motor TEXT NULL
        COMMENT 'Número do motor',

    codigo_da_cor TEXT NULL
        COMMENT 'Código da cor',

    descricao_da_cor TEXT NULL
        COMMENT 'Descrição da cor',

    potencia_motor DECIMAL(10,2) NULL
        COMMENT 'Potência do motor',

    cap_trac_max DECIMAL(10,4) NULL
        COMMENT 'Capacidade máxima de tração',

    cilindradas_cc DECIMAL(10,2) NULL
        COMMENT 'Cilindrada do motor em centímetros cúbicos',

    distancia_entre_eixo DECIMAL(10,2) NULL
        COMMENT 'Distância entre eixos',

    peso_liquido_ton DECIMAL(10,4) NULL
        COMMENT 'Peso líquido em toneladas',

    peso_bruto_ton DECIMAL(10,4) NULL
        COMMENT 'Peso bruto em toneladas',

    tipo_de_veiculo TEXT NULL
        COMMENT 'Código do tipo de veículo',

    especie_do_veiculo TEXT NULL
        COMMENT 'Código da espécie do veículo',

    tipo_do_combustivel TEXT NULL
        COMMENT 'Código do tipo de combustível',

    tipo_de_pintura TEXT NULL
        COMMENT 'Código do tipo de pintura',

    condicao_do_veiculo TEXT NULL
        COMMENT 'Código da condição do veículo',

    cap_ocup_max SMALLINT NULL
        COMMENT 'Capacidade máxima de ocupantes',

    serie_number TEXT NULL
        COMMENT 'Número de série adicional informado pelo SAP',

    byd_icms_st_taxpayer TEXT NULL
        COMMENT 'Indicador BYD referente a contribuinte de ICMS ST',

    byd_cnpj_number TEXT NULL
        COMMENT 'CNPJ BYD informado no documento',

    manufacturing_year SMALLINT NULL
        COMMENT 'Ano de fabricação do veículo',

    model_year SMALLINT NULL
        COMMENT 'Ano modelo do veículo',

    vin_condition TEXT NULL
        COMMENT 'Condição do VIN',

    code_brand_mode TEXT NULL
        COMMENT 'Código de marca/modelo',

    manufacture_year SMALLINT NULL
        COMMENT 'Ano de fabricação proveniente de campo adicional da ZSDBIL17',

    model_year_1 SMALLINT NULL
        COMMENT 'Ano modelo proveniente de campo adicional da ZSDBIL17',


    /*
    =========================================================
    14. IBS / CBS
    =========================================================
    */

    cbs3_base DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo CBS',

    cbs3_rate DECIMAL(18,9) NULL
        COMMENT 'Alíquota CBS',

    cbs3_val DECIMAL(18,2) NULL
        COMMENT 'Valor CBS',

    ib3s_base DECIMAL(18,2) NULL
        COMMENT 'Base de cálculo IBS',

    ib3s_rate DECIMAL(18,9) NULL
        COMMENT 'Alíquota IBS',

    ib3s_val DECIMAL(18,2) NULL
        COMMENT 'Valor IBS',

    ibs_cbs_tax_sitn TEXT NULL
        COMMENT 'Situação tributária IBS/CBS',

    ibs_cbs_tax_sitn_code TEXT NULL
        COMMENT 'Código da situação tributária IBS/CBS',

    ibs_cbs_tax_classification_code TEXT NULL
        COMMENT 'Código de classificação tributária IBS/CBS',


    /*
    =========================================================
    15. LOGÍSTICA / CONTABILIDADE / DADOS DO MATERIAL
    =========================================================
    */

    proc_time TIME NULL
        COMMENT 'Horário de processamento informado pelo SAP',

    delivery_allocation_address TEXT NULL
        COMMENT 'Endereço ou referência de alocação da entrega',

    storage_location TEXT NULL
        COMMENT 'Depósito/local de armazenamento',

    movement_type TEXT NULL
        COMMENT 'Tipo de movimento SAP',

    assignment_number TEXT NULL
        COMMENT 'Número de atribuição contábil',

    journal_entry_document TEXT NULL
        COMMENT 'Número do documento contábil',

    um_basic TEXT NULL
        COMMENT 'Unidade de medida básica do material',

    profit_center TEXT NULL
        COMMENT 'Centro de lucro',

    produced_in_house TEXT NULL
        COMMENT 'Indicador de produção interna',

    valuation_class TEXT NULL
        COMMENT 'Classe de avaliação do material',

    price_control TEXT NULL
        COMMENT 'Indicador de controle de preço',

    acct_assmt_grp_mat TEXT NULL
        COMMENT 'Grupo de atribuição contábil do material',

    mat_item_category_group TEXT NULL
        COMMENT 'Grupo de categoria de item do material',

    material_group_2 TEXT NULL
        COMMENT 'Grupo de material adicional',

    um_sales TEXT NULL
        COMMENT 'Unidade de medida de vendas',


    /*
    =========================================================
    16. AUDITORIA / CONTROLE DA CARGA
    =========================================================
    */

    dt_carga DATETIME(6) NULL
        COMMENT 'Data e hora da carga original na Bronze',

    id_execucao TEXT NULL
        COMMENT 'Identificador UUID da execução que originou o registro',

    usuario TEXT NULL
        COMMENT 'Usuário associado à carga de origem',

    source_file TEXT NULL
        COMMENT 'Arquivo de origem do registro',

    source_status VARCHAR(20) NOT NULL
        COMMENT 'Status do registro na reconciliação da Bronze',

    first_seen_at DATETIME NULL
        COMMENT 'Primeira vez em que o registro/documento foi observado',

    last_seen_at DATETIME NULL
        COMMENT 'Última vez em que o registro/documento foi observado',

    missing_since DATETIME NULL
        COMMENT 'Data e hora desde quando o registro está ausente no snapshot SAP',


    /*
    =========================================================
    ÍNDICES DE CONSULTA
    =========================================================
    */

    INDEX idx_sz17_id_bronze (id_bronze),

    INDEX idx_sz17_recon_hash (reconciliation_hash),

    INDEX idx_sz17_sap_doc (sap_document),

    INDEX idx_sz17_invoice (invoice_number),

    INDEX idx_sz17_issuance (issuance_date),

    INDEX idx_sz17_chassis (chassis_serial_number),

    INDEX idx_sz17_access_key (chave_de_acesso),

    INDEX idx_sz17_status_date (source_status, issuance_date)

) ENGINE = InnoDB
  ROW_FORMAT = DYNAMIC

  COMMENT = 'Movimentações de saída da ZSDBIL17 na camada Silver; preserva todos os campos da Bronze, tipando números e datas e mantendo textos flexíveis para posterior normalização e validação.';
