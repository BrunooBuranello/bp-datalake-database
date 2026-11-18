-- ============================================================
-- TABELA: bronze_fbl5n
-- CAMADA: Bronze (histórico das partidas de clientes, sem duplicar)
--
-- MIGRAÇÃO ÚNICA (18/11/2026, ADR-043 do sap_service):
-- A bronze_fbl5n antiga era APPEND com janela de 2 dias sobreposta
-- (3.105 grupos duplicados, 2.396 linhas de rodapé de total gravadas como
-- dado) e parou em 01/09/2026. O Bruno pediu para apagar e recarregar tudo
-- do SAP, mês a mês, no padrão stage -> procedure da ZFIGLM_48B.
--
-- ORIGEM:
-- FBL5N (BR00 + BR70, todas as partidas por data de lançamento), layout
-- global /BRUNO_FBL5N, CSV exportado pelo BYD Sales Operation
-- (sap_service/services/workflows/fbl5n.py).
--
-- O QUE ESTE SCRIPT FAZ (nesta ordem):
--   1. Backup integral da tabela antiga em bronze_fbl5n_bkp_20261118
--      (segundos; falha se o backup já existir: nunca sobrescreve).
--   2. DROP da tabela antiga (o layout mudou: entram item, frmpgto e
--      condicoes_pgto; saem 5 colunas que o layout novo não exporta).
--   3. CREATE da tabela nova, com o mesmo nome (auto incremento começa em 1).
--
-- PRÉ-REQUISITOS:
-- - Orquestrador desligado e nenhuma FBL5N na fila SAP.
-- - Conferir o processlist antes (DROP pede trava de metadados).
-- - Aplicar ANTES de 02 e 03 e antes do deploy do app.
--
-- ROLLBACK:
--   DROP TABLE bp_datalake.bronze_fbl5n;
--   RENAME TABLE bp_datalake.bronze_fbl5n_bkp_20261118
--             TO bp_datalake.bronze_fbl5n;
-- (e voltar o app para o commit anterior ao ADR-043).
-- O backup pode ser apagado depois que a recarga for conferida.
-- ============================================================


-- ------------------------------------------------------------
-- 1. BACKUP
-- ------------------------------------------------------------
CREATE TABLE bp_datalake.bronze_fbl5n_bkp_20261118
    LIKE bp_datalake.bronze_fbl5n;

INSERT INTO bp_datalake.bronze_fbl5n_bkp_20261118
SELECT * FROM bp_datalake.bronze_fbl5n;


-- ------------------------------------------------------------
-- 2. TABELA ANTIGA FORA
-- ------------------------------------------------------------
DROP TABLE bp_datalake.bronze_fbl5n;


-- ------------------------------------------------------------
-- 3. TABELA NOVA
-- ------------------------------------------------------------
CREATE TABLE bp_datalake.bronze_fbl5n (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- ========================================================
    -- COLUNAS DO SAP (ordem do CSV, layout /BRUNO_FBL5N)
    -- Bronze fiel à origem: tudo TEXT, tipagem fica para a Silver.
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
    -- AUDITORIA
    -- ========================================================
    -- Período de lançamento pedido ao SAP na execução que trouxe a linha.
    scope_start TEXT NULL,
    scope_end TEXT NULL,
    dt_carga TEXT NULL,
    id_execucao TEXT NULL,
    source_file TEXT NULL,
    usuario TEXT NULL,

    -- ========================================================
    -- CONTROLE (padrão Z17 / ZFIGLM_48B)
    -- ========================================================

    -- MD5 de empresa + no_documento + ano do lançamento + item.
    -- Identifica a PARTIDA (uma linha): na FBL5N o item é parte da chave,
    -- então, diferente da ZFIGLM_48B, o hash é único na tabela.
    reconciliation_hash BINARY(16) NOT NULL,

    -- ACTIVE  = presente no último snapshot que cobriu a data de lançamento.
    -- MISSING = sumiu de um snapshot que cobria a data (ex.: estorno
    --           que apagou a partida). Nunca é apagada da Bronze.
    source_status VARCHAR(10) NOT NULL,

    first_seen_at DATETIME NOT NULL,
    last_seen_at DATETIME NOT NULL,
    missing_since DATETIME NULL,

    PRIMARY KEY (id),

    -- Uma linha por partida: protege contra duplicar mesmo se a procedure
    -- tiver erro (o problema da tabela antiga).
    UNIQUE KEY uk_bronze_fbl5n_hash (reconciliation_hash),

    -- Consultas mais comuns (Data Query, conciliação de AR, atribuição).
    INDEX idx_bronze_fbl5n_no_documento (no_documento(20)),
    INDEX idx_bronze_fbl5n_doc_faturamento (doc_faturamento(20)),
    INDEX idx_bronze_fbl5n_data_de_lancamento (data_de_lancamento(10)),
    INDEX idx_bronze_fbl5n_conta (conta(20)),
    INDEX idx_bronze_fbl5n_doc_compensacao (doc_compensacao(20)),
    INDEX idx_bronze_fbl5n_source_status (source_status),
    INDEX idx_bronze_fbl5n_id_execucao (id_execucao(36))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci

COMMENT = 'FBL5N partidas de clientes (SAP, BR00+BR70), histórico reconciliado por partida';
