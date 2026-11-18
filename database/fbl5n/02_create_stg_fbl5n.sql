-- ============================================================
-- TABELA: stg_fbl5n
-- CAMADA: Staging (snapshot da última execução)
--
-- ORIGEM:
-- CSV da FBL5N (layout /BRUNO_FBL5N) exportado pelo BYD Sales Operation
-- (sap_service/services/workflows/fbl5n.py, ADR-043 do sap_service).
--
-- OBJETIVO:
-- Receber SÓ a foto da última execução. O app faz TRUNCATE + INSERT aqui e
-- em seguida chama sp_stg_reconcile_fbl5n_bronze, que leva a foto para a
-- bronze_fbl5n sem duplicar (mesmo desenho da ZFIGLM_48B).
--
-- REGRAS:
-- - Mesmas 21 colunas do SAP da Bronze, todas TEXT.
-- - NADA é descartado pelo app: a linha de rodapé (total do SAP, só com
--   montante) também entra aqui; a procedure usa ela como total de controle.
-- - reconciliation_hash é preenchido pela procedure (não pelo app).
--
-- APLICAR ANTES do deploy do app que grava nesta tabela.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.stg_fbl5n (

    -- ========================================================
    -- COLUNAS DO SAP (ordem do CSV)
    -- ========================================================
    empresa TEXT NULL,
    loc_negocios TEXT NULL,
    conta TEXT NULL,
    chave_referencia_3 TEXT NULL,
    referencia TEXT NULL,
    data_de_lancamento TEXT NULL,
    vencimento_liquido TEXT NULL,
    item TEXT NULL,
    tipo_de_documento TEXT NULL,
    montante_em_moeda_interna TEXT NULL,
    cod_razao_especial TEXT NULL,
    texto TEXT NULL,
    no_documento TEXT NULL,
    doc_faturamento TEXT NULL,
    atribuicao TEXT NULL,
    doc_compensacao TEXT NULL,
    data_de_compensacao TEXT NULL,
    conta_do_razao TEXT NULL,
    frmpgto TEXT NULL,
    condicoes_pgto TEXT NULL,
    solicitacao_de_l_c TEXT NULL,

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
    -- MD5 de empresa + no_documento + ano + item. Preenchido pela procedure.
    reconciliation_hash BINARY(16) NULL,

    INDEX idx_stg_fbl5n_hash (reconciliation_hash)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'FBL5N (SAP), snapshot da última execução antes da reconciliação';
