/*
===============================================================================
PROCEDURE: sp_stg_reconcile_va05_sales_order_bronze(p_scope_start, p_scope_end)
===============================================================================

OBJETIVO
-------------------------------------------------------------------------------
Reconciliar a foto da VA05 que o app grava na stg_va05_sales_order com o
histórico da bronze_va05_sales_order, sem duplicar. Mesmo desenho da
sp_stg_reconcile_fbl5n_bronze (ADR-043 do sap_service).

    SAP (VA05, data do documento) -> CSV -> stg_va05_sales_order (TRUNCATE + INSERT)
                                                  |
                                                  | reconciliation_hash
                                                  v
                             sp_stg_reconcile_va05_sales_order_bronze
                                                  |
                                                  v
                             bronze_va05_sales_order (uma linha por item)


PARÂMETROS
-------------------------------------------------------------------------------
p_scope_start / p_scope_end ('AAAA-MM-DD'): período de DATA DO DOCUMENTO
pedido ao SAP nesta execução. É o universo do MISSING: só some quem tinha
data do documento dentro do período pedido.


CHAVE DE RECONCILIAÇÃO
-------------------------------------------------------------------------------
reconciliation_hash = MD5(documento_de_vendas | item), BINARY(16).
Identifica o ITEM da ordem (medido em 27/11/2026: 3.932 itens, 0 repetidos).

Fora da chave, de propósito: status, quantidades confirmadas, valores,
remessa, bloqueios. Mudam depois da criação e são atualizados a cada
execução que cobre a data do documento.


REGRAS
-------------------------------------------------------------------------------
1. Período inválido ou staging vazia: BLOQUEIA.
2. Linha sem documento_de_vendas, item ou data_do_documento: BLOQUEIA
   (identidade duvidosa).
3. Data do documento fora do período pedido: BLOQUEIA (o MISSING ficaria
   errado).
4. Mesmo item (hash) duas vezes no snapshot: BLOQUEIA.
5. Item novo: insere com first_seen_at = last_seen_at = agora.
6. Item conhecido: substitui pelo estado atual, preservando first_seen_at;
   last_seen_at = agora; volta a ACTIVE.
7. Item ACTIVE da Bronze com data do documento no período pedido que sumiu
   do snapshot: vira MISSING (missing_since). Nunca é apagado.


AUDITORIA
-------------------------------------------------------------------------------
Toda execução (sucesso ou falha) grava em etl_execution_log. Ao final, um
SELECT devolve o resumo para o app registrar no log da tarefa.
===============================================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_stg_reconcile_va05_sales_order_bronze;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_stg_reconcile_va05_sales_order_bronze(
    -- Collation igual à das tabelas (o padrão do banco é 0900_ai_ci):
    -- evita "Illegal mix of collations" ao comparar com data_do_documento.
    IN p_scope_start VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_scope_end VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    -- ------------------------------------------------------------------
    -- 1. CONTROLE E MÉTRICAS
    -- ------------------------------------------------------------------
    DECLARE v_started_at DATETIME DEFAULT NOW();
    DECLARE v_finished_at DATETIME;
    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;

    DECLARE v_source_rows INT DEFAULT 0;
    DECLARE v_invalid_identity_rows INT DEFAULT 0;
    DECLARE v_out_of_scope_rows INT DEFAULT 0;
    DECLARE v_duplicate_hashes INT DEFAULT 0;
    DECLARE v_existing_rows INT DEFAULT 0;
    DECLARE v_new_rows INT DEFAULT 0;
    DECLARE v_deleted_rows INT DEFAULT 0;
    DECLARE v_inserted_rows INT DEFAULT 0;
    DECLARE v_missing_updated INT DEFAULT 0;


    -- ------------------------------------------------------------------
    -- 2. ERRO: ROLLBACK + LOG ERROR + devolve o erro original
    -- ------------------------------------------------------------------
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_va05_prev;

        SET v_finished_at = NOW();

        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name, source_table, target_table, execution_status,
            executed_by, started_at, finished_at, source_rows, selected_rows,
            inserted_rows, updated_rows, rejected_rows, error_code,
            error_message, audit_details, execution_duration_seconds
        )
        VALUES (
            'sp_stg_reconcile_va05_sales_order_bronze',
            'stg_va05_sales_order',
            'bronze_va05_sales_order',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_source_rows,
            0,
            0,
            v_invalid_identity_rows + v_out_of_scope_rows + v_duplicate_hashes,
            v_error_code,
            v_error_message,
            JSON_OBJECT(
                'scope_start', p_scope_start,
                'scope_end', p_scope_end,
                'invalid_identity_rows', v_invalid_identity_rows,
                'out_of_scope_rows', v_out_of_scope_rows,
                'duplicate_hashes', v_duplicate_hashes
            ),
            TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
        );

        RESIGNAL;
    END;


    -- ------------------------------------------------------------------
    -- 3. PARÂMETROS E STAGING COM DADOS (regra 1)
    -- ------------------------------------------------------------------
    IF p_scope_start IS NULL OR p_scope_end IS NULL OR p_scope_start > p_scope_end THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: periodo da data do documento invalido.';
    END IF;

    SELECT COUNT(*) INTO v_source_rows FROM bp_datalake.stg_va05_sales_order;

    IF v_source_rows = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: staging vazia.';
    END IF;


    -- ------------------------------------------------------------------
    -- 4. VALIDAÇÕES (regras 2 e 3)
    -- ------------------------------------------------------------------
    SELECT COUNT(*) INTO v_invalid_identity_rows
    FROM bp_datalake.stg_va05_sales_order
    WHERE TRIM(COALESCE(documento_de_vendas, '')) = ''
       OR TRIM(COALESCE(item, '')) = ''
       OR TRIM(COALESCE(data_do_documento, '')) = '';

    IF v_invalid_identity_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: linhas sem documento de vendas, item ou data do documento.';
    END IF;

    -- O CSV traz a data como AAAA-MM-DD: os 10 primeiros caracteres comparam
    -- como texto com os parâmetros.
    SELECT COUNT(*) INTO v_out_of_scope_rows
    FROM bp_datalake.stg_va05_sales_order
    WHERE LEFT(TRIM(data_do_documento), 10) < p_scope_start
       OR LEFT(TRIM(data_do_documento), 10) > p_scope_end;

    IF v_out_of_scope_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: itens com data do documento fora do periodo pedido.';
    END IF;


    -- ------------------------------------------------------------------
    -- 5. HASH DO ITEM (regra 4)
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.stg_va05_sales_order
    SET reconciliation_hash = UNHEX(MD5(CONCAT_WS(
        '|',
        TRIM(documento_de_vendas),
        TRIM(item)
    )));

    SELECT COUNT(*) INTO v_duplicate_hashes
    FROM (
        SELECT reconciliation_hash
        FROM bp_datalake.stg_va05_sales_order
        GROUP BY reconciliation_hash
        HAVING COUNT(*) > 1
    ) d;

    IF v_duplicate_hashes > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: mesmo item (documento de vendas + item) repetido no snapshot.';
    END IF;


    START TRANSACTION;


    -- ------------------------------------------------------------------
    -- 6. O QUE A BRONZE JÁ TEM (first_seen_at preservado)
    -- ------------------------------------------------------------------
    DROP TEMPORARY TABLE IF EXISTS tmp_va05_prev;
    CREATE TEMPORARY TABLE tmp_va05_prev (
        reconciliation_hash BINARY(16) NOT NULL,
        first_seen_at DATETIME NOT NULL,
        PRIMARY KEY (reconciliation_hash)
    );

    INSERT INTO tmp_va05_prev
    SELECT b.reconciliation_hash, b.first_seen_at
    FROM bp_datalake.bronze_va05_sales_order b
    INNER JOIN bp_datalake.stg_va05_sales_order s
        ON s.reconciliation_hash = b.reconciliation_hash;

    SET v_existing_rows = ROW_COUNT();
    SET v_new_rows = v_source_rows - v_existing_rows;


    -- ------------------------------------------------------------------
    -- 7. SUBSTITUIR OS ITENS DO SNAPSHOT PELO ESTADO ATUAL (regras 5 e 6)
    -- ------------------------------------------------------------------
    -- DELETE + INSERT em vez de UPDATE coluna a coluna: com 97 colunas, o
    -- UPDATE seria fácil de esquecer um campo; o INSERT copia a linha inteira.
    DELETE b
    FROM bp_datalake.bronze_va05_sales_order b
    INNER JOIN tmp_va05_prev p
        ON p.reconciliation_hash = b.reconciliation_hash;

    SET v_deleted_rows = ROW_COUNT();

    INSERT INTO bp_datalake.bronze_va05_sales_order (
        documento_de_vendas, item, tipo_doc_vendas,
        descricao_do_tipo_de_documento_de_vendas, ctg_documento_sd,
        descricao_do_documento_de_vendas, data_do_documento, hora_registro,
        criado_em, criado_por, motivo_da_ordem, descricao_do_motivo_da_ordem,
        referencia_de_cliente, referencia_de_cliente_cabecalho,
        organizacao_de_vendas, nome_da_organizacao_de_vendas,
        canal_de_distribuicao, nome_de_canal_de_distribuicao,
        setor_de_atividade, nome_do_setor_de_atividade, escritorio_de_vendas,
        equipe_de_vendas, centro, deposito, local_expedicao_recebimento,
        emissor_da_ordem, nome_emissor_ordem,
        bloco_de_enderecos_emissor_da_ordem, parceiro, nome_do_parceiro,
        funcao_parceiro, bloco_de_enderecos_parceiro, no_endereco,
        funcao_de_parceiro_pessoal, no_pessoal, nome_empregado,
        id_do_empregado, material, descricao_de_material, lote,
        quantidade_da_ordem_item, unidade_de_venda, umb,
        quantidade_confirmada_item, quantidade_prevista, no_div_remessa,
        ctg_divisao_remessa, quantidade_da_ordem_divisao_da_remessa,
        quantidade_confirmada_divisao_remessa,
        quantidade_arredondada_divisao_remessa, valor_liquido_item,
        valor_liquido_cabecalho, preco_liquido, unidade_de_preco,
        unidade_preco_por, moeda_do_documento, taxa_de_cambio,
        ctg_taxa_cambio, data_fixacao_preco, status_global,
        descricao_de_status_global, item_de_status_global,
        descricao_de_item_de_status_global, status_global_da_remessa_item,
        descricao_item_status_global_de_remessa,
        status_global_remessa_todos_os_itens,
        descricao_de_status_global_da_remessa, data_de_remessa,
        data_de_disponibilizacao_do_material, data_sm, bloqueio_remessa,
        descricao_do_bloqueio_da_remessa, bloq_doc_faturamento,
        descricao_bloqueio_documento_faturamento, motivo_de_recusa,
        descricao_do_motivo_da_recusa, devolucao, doc_estorno_p_parc,
        data_doc_estorno, segmento_necessidade, inicio_do_contrato,
        fim_do_contrato, contrato_assinado, periodo_valid_contr,
        unidade_periodo_val, ctg_periodo_validade, data_de_aceitacao,
        data_de_instalacao, data_desmontagem, data_rescisao_desej,
        entrada_rescisao, motivo_da_rescisao, parte_rescindente,
        esquema_de_rescisao, atividade, descricao_da_acao, data_atividade,
        scope_start, scope_end, dt_carga, id_execucao, source_file, usuario,
        reconciliation_hash, source_status, first_seen_at, last_seen_at,
        missing_since
    )
    SELECT
        s.documento_de_vendas, s.item, s.tipo_doc_vendas,
        s.descricao_do_tipo_de_documento_de_vendas, s.ctg_documento_sd,
        s.descricao_do_documento_de_vendas, s.data_do_documento,
        s.hora_registro, s.criado_em, s.criado_por, s.motivo_da_ordem,
        s.descricao_do_motivo_da_ordem, s.referencia_de_cliente,
        s.referencia_de_cliente_cabecalho, s.organizacao_de_vendas,
        s.nome_da_organizacao_de_vendas, s.canal_de_distribuicao,
        s.nome_de_canal_de_distribuicao, s.setor_de_atividade,
        s.nome_do_setor_de_atividade, s.escritorio_de_vendas,
        s.equipe_de_vendas, s.centro, s.deposito,
        s.local_expedicao_recebimento, s.emissor_da_ordem,
        s.nome_emissor_ordem, s.bloco_de_enderecos_emissor_da_ordem,
        s.parceiro, s.nome_do_parceiro, s.funcao_parceiro,
        s.bloco_de_enderecos_parceiro, s.no_endereco,
        s.funcao_de_parceiro_pessoal, s.no_pessoal, s.nome_empregado,
        s.id_do_empregado, s.material, s.descricao_de_material, s.lote,
        s.quantidade_da_ordem_item, s.unidade_de_venda, s.umb,
        s.quantidade_confirmada_item, s.quantidade_prevista, s.no_div_remessa,
        s.ctg_divisao_remessa, s.quantidade_da_ordem_divisao_da_remessa,
        s.quantidade_confirmada_divisao_remessa,
        s.quantidade_arredondada_divisao_remessa, s.valor_liquido_item,
        s.valor_liquido_cabecalho, s.preco_liquido, s.unidade_de_preco,
        s.unidade_preco_por, s.moeda_do_documento, s.taxa_de_cambio,
        s.ctg_taxa_cambio, s.data_fixacao_preco, s.status_global,
        s.descricao_de_status_global, s.item_de_status_global,
        s.descricao_de_item_de_status_global, s.status_global_da_remessa_item,
        s.descricao_item_status_global_de_remessa,
        s.status_global_remessa_todos_os_itens,
        s.descricao_de_status_global_da_remessa, s.data_de_remessa,
        s.data_de_disponibilizacao_do_material, s.data_sm, s.bloqueio_remessa,
        s.descricao_do_bloqueio_da_remessa, s.bloq_doc_faturamento,
        s.descricao_bloqueio_documento_faturamento, s.motivo_de_recusa,
        s.descricao_do_motivo_da_recusa, s.devolucao, s.doc_estorno_p_parc,
        s.data_doc_estorno, s.segmento_necessidade, s.inicio_do_contrato,
        s.fim_do_contrato, s.contrato_assinado, s.periodo_valid_contr,
        s.unidade_periodo_val, s.ctg_periodo_validade, s.data_de_aceitacao,
        s.data_de_instalacao, s.data_desmontagem, s.data_rescisao_desej,
        s.entrada_rescisao, s.motivo_da_rescisao, s.parte_rescindente,
        s.esquema_de_rescisao, s.atividade, s.descricao_da_acao,
        s.data_atividade, s.scope_start, s.scope_end, s.dt_carga,
        s.id_execucao, s.source_file, s.usuario,
        s.reconciliation_hash,
        'ACTIVE',
        COALESCE(p.first_seen_at, v_now),
        v_now,
        NULL
    FROM bp_datalake.stg_va05_sales_order s
    LEFT JOIN tmp_va05_prev p
        ON p.reconciliation_hash = s.reconciliation_hash;

    SET v_inserted_rows = ROW_COUNT();

    -- Todo item da staging tem que ter entrado (proteção contra JOIN errado).
    IF v_inserted_rows <> v_source_rows THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao VA05 bloqueada: itens inseridos diferentes dos itens da staging.';
    END IF;


    -- ------------------------------------------------------------------
    -- 8. MISSING: sumiu de um snapshot que cobria a data (regra 7)
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.bronze_va05_sales_order b
    LEFT JOIN bp_datalake.stg_va05_sales_order s
        ON s.reconciliation_hash = b.reconciliation_hash
    SET
        b.source_status = 'MISSING',
        b.missing_since = COALESCE(b.missing_since, v_now)
    WHERE s.reconciliation_hash IS NULL
      AND b.source_status = 'ACTIVE'
      AND LEFT(b.data_do_documento, 10) BETWEEN p_scope_start AND p_scope_end;

    SET v_missing_updated = ROW_COUNT();


    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_va05_prev;

    SET v_finished_at = NOW();


    -- ------------------------------------------------------------------
    -- 9. LOG DE SUCESSO + RESUMO PARA O APP
    -- ------------------------------------------------------------------
    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name, source_table, target_table, execution_status,
        executed_by, started_at, finished_at, source_rows, selected_rows,
        inserted_rows, updated_rows, rejected_rows, error_code,
        error_message, audit_details, execution_duration_seconds
    )
    VALUES (
        'sp_stg_reconcile_va05_sales_order_bronze',
        'stg_va05_sales_order',
        'bronze_va05_sales_order',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_source_rows,
        v_new_rows,
        v_existing_rows + v_missing_updated,
        0,
        NULL,
        NULL,
        JSON_OBJECT(
            'scope_start', p_scope_start,
            'scope_end', p_scope_end,
            'existing_rows', v_existing_rows,
            'new_rows', v_new_rows,
            'replaced_rows', v_deleted_rows,
            'inserted_rows', v_inserted_rows,
            'missing_rows_updated', v_missing_updated
        ),
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
    );

    SET v_execution_id = LAST_INSERT_ID();

    SELECT
        v_execution_id AS execution_id,
        v_source_rows AS staging_rows,
        v_new_rows AS new_rows,
        v_existing_rows AS existing_rows,
        v_inserted_rows AS inserted_rows,
        v_missing_updated AS missing_rows,
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at) AS duration_seconds;

END$$

DELIMITER ;
