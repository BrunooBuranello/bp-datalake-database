-- ============================================================
-- TABELA: stg_va05_sales_order
-- CAMADA: Staging (snapshot da última execução)
--
-- ORIGEM:
-- SAP VA05 (lista de ordens de venda), filtro pela data do documento
-- (SAUDAT), todas as colunas do ALV, CSV (csv-LEAN-STANDARD) exportado pelo
-- BYD - Sales Demand Center (sap_service, robô VA05 na fila SAP).
--
-- OBJETIVO:
-- Receber SÓ a foto da última execução. O app faz TRUNCATE + INSERT aqui e
-- em seguida chama sp_stg_reconcile_va05_sales_order_bronze, que leva a foto
-- para a bronze_va05_sales_order sem duplicar (mesmo desenho da FBL5N).
--
-- REGRAS:
-- - Mesmas 97 colunas da Bronze, todas TEXT, nomes = cabeçalho do CSV
--   normalizado pelo normalize_dataframe (sem acento, minúsculas, "_").
-- - reconciliation_hash é preenchido pela procedure (não pelo app).
--
-- APLICAR ANTES do deploy do app que grava nesta tabela.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.stg_va05_sales_order (

    -- ========================================================
    -- IDENTIFICAÇÃO DA ORDEM
    -- ========================================================
    documento_de_vendas TEXT NULL,
    item TEXT NULL,
    tipo_doc_vendas TEXT NULL,
    descricao_do_tipo_de_documento_de_vendas TEXT NULL,
    ctg_documento_sd TEXT NULL,
    descricao_do_documento_de_vendas TEXT NULL,
    data_do_documento TEXT NULL,
    hora_registro TEXT NULL,
    criado_em TEXT NULL,
    criado_por TEXT NULL,
    motivo_da_ordem TEXT NULL,
    descricao_do_motivo_da_ordem TEXT NULL,
    referencia_de_cliente TEXT NULL,
    referencia_de_cliente_cabecalho TEXT NULL,

    -- ========================================================
    -- ORGANIZAÇÃO DE VENDAS E LOGÍSTICA
    -- ========================================================
    organizacao_de_vendas TEXT NULL,
    nome_da_organizacao_de_vendas TEXT NULL,
    canal_de_distribuicao TEXT NULL,
    nome_de_canal_de_distribuicao TEXT NULL,
    setor_de_atividade TEXT NULL,
    nome_do_setor_de_atividade TEXT NULL,
    escritorio_de_vendas TEXT NULL,
    equipe_de_vendas TEXT NULL,
    centro TEXT NULL,
    deposito TEXT NULL,
    local_expedicao_recebimento TEXT NULL,

    -- ========================================================
    -- CLIENTE E PARCEIROS
    -- ========================================================
    emissor_da_ordem TEXT NULL,
    nome_emissor_ordem TEXT NULL,
    bloco_de_enderecos_emissor_da_ordem TEXT NULL,
    parceiro TEXT NULL,
    nome_do_parceiro TEXT NULL,
    funcao_parceiro TEXT NULL,
    bloco_de_enderecos_parceiro TEXT NULL,
    no_endereco TEXT NULL,
    funcao_de_parceiro_pessoal TEXT NULL,
    no_pessoal TEXT NULL,
    nome_empregado TEXT NULL,
    id_do_empregado TEXT NULL,

    -- ========================================================
    -- MATERIAL E QUANTIDADES
    -- ========================================================
    material TEXT NULL,
    descricao_de_material TEXT NULL,
    lote TEXT NULL,
    quantidade_da_ordem_item TEXT NULL,
    unidade_de_venda TEXT NULL,
    umb TEXT NULL,
    quantidade_confirmada_item TEXT NULL,
    quantidade_prevista TEXT NULL,
    no_div_remessa TEXT NULL,
    ctg_divisao_remessa TEXT NULL,
    quantidade_da_ordem_divisao_da_remessa TEXT NULL,
    quantidade_confirmada_divisao_remessa TEXT NULL,
    quantidade_arredondada_divisao_remessa TEXT NULL,

    -- ========================================================
    -- VALORES
    -- ========================================================
    valor_liquido_item TEXT NULL,
    valor_liquido_cabecalho TEXT NULL,
    preco_liquido TEXT NULL,
    unidade_de_preco TEXT NULL,
    unidade_preco_por TEXT NULL,
    moeda_do_documento TEXT NULL,
    taxa_de_cambio TEXT NULL,
    ctg_taxa_cambio TEXT NULL,
    data_fixacao_preco TEXT NULL,

    -- ========================================================
    -- STATUS, REMESSA E BLOQUEIOS
    -- ========================================================
    status_global TEXT NULL,
    descricao_de_status_global TEXT NULL,
    item_de_status_global TEXT NULL,
    descricao_de_item_de_status_global TEXT NULL,
    status_global_da_remessa_item TEXT NULL,
    descricao_item_status_global_de_remessa TEXT NULL,
    status_global_remessa_todos_os_itens TEXT NULL,
    descricao_de_status_global_da_remessa TEXT NULL,
    data_de_remessa TEXT NULL,
    data_de_disponibilizacao_do_material TEXT NULL,
    data_sm TEXT NULL,
    bloqueio_remessa TEXT NULL,
    descricao_do_bloqueio_da_remessa TEXT NULL,
    bloq_doc_faturamento TEXT NULL,
    descricao_bloqueio_documento_faturamento TEXT NULL,
    motivo_de_recusa TEXT NULL,
    descricao_do_motivo_da_recusa TEXT NULL,
    devolucao TEXT NULL,
    doc_estorno_p_parc TEXT NULL,
    data_doc_estorno TEXT NULL,
    segmento_necessidade TEXT NULL,

    -- ========================================================
    -- CONTRATO E SERVIÇO (vazias nas ordens de venda hoje;
    -- ficam porque a VA05 exporta e a Bronze é fiel à origem)
    -- ========================================================
    inicio_do_contrato TEXT NULL,
    fim_do_contrato TEXT NULL,
    contrato_assinado TEXT NULL,
    periodo_valid_contr TEXT NULL,
    unidade_periodo_val TEXT NULL,
    ctg_periodo_validade TEXT NULL,
    data_de_aceitacao TEXT NULL,
    data_de_instalacao TEXT NULL,
    data_desmontagem TEXT NULL,
    data_rescisao_desej TEXT NULL,
    entrada_rescisao TEXT NULL,
    motivo_da_rescisao TEXT NULL,
    parte_rescindente TEXT NULL,
    esquema_de_rescisao TEXT NULL,
    atividade TEXT NULL,
    descricao_da_acao TEXT NULL,
    data_atividade TEXT NULL,

    -- ========================================================
    -- AUDITORIA (mesmo significado da Bronze)
    -- ========================================================
    scope_start TEXT NULL,
    scope_end TEXT NULL,
    dt_carga TEXT NULL,
    id_execucao TEXT NULL,
    source_file TEXT NULL,
    usuario TEXT NULL,

    -- ========================================================
    -- CONTROLE
    -- ========================================================
    -- MD5 de documento_de_vendas + item. Preenchido pela procedure.
    reconciliation_hash BINARY(16) NULL,

    INDEX idx_stg_va05_sales_order_hash (reconciliation_hash)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'VA05 ordens de venda (SAP), snapshot da última execução antes da reconciliação';
