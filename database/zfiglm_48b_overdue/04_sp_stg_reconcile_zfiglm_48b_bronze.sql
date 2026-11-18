/*
===============================================================================
PROCEDURE: sp_stg_reconcile_zfiglm_48b_bronze
===============================================================================

OBJETIVO
-------------------------------------------------------------------------------
Reconciliar a foto atual da ZFIGLM_48B (Overdue), que o app grava na
stg_zfiglm_48b_overdue, com o histórico da bronze_zfiglm_48b_overdue.
Mesmo desenho da sp_stg_reconcile_zsdbil17_bronze (Z17), ADR-036 do
sap_service.

    SAP -> CSV -> stg_zfiglm_48b_overdue (TRUNCATE + INSERT pelo app)
                        |
                        | reconciliation_hash
                        v
           sp_stg_reconcile_zfiglm_48b_bronze
                        |
                        v
           bronze_zfiglm_48b_overdue (histórico, sem duplicar)


CHAVE DE RECONCILIAÇÃO
-------------------------------------------------------------------------------
O reconciliation_hash representa um DOCUMENTO, não uma linha:

    numero_de_documento_do_sap + empresa + numero_da_nf + data_do_faturamento

MD5 guardado como BINARY(16). Uma NF com 50 itens = 50 linhas e 1 hash.

Fora do hash, de propósito (validado nos dados de 17-18/11/2026):
- key_reference: começa vazia e é preenchida depois (30 documentos);
- valor_da_nf: mudou em 4 documentos entre execuções.
Elas continuam na tabela e são atualizadas a cada execução.


REGRAS
-------------------------------------------------------------------------------
1. Staging vazia, ou linha sem documento SAP / empresa / data do faturamento:
   BLOQUEIA (melhor parar do que reconciliar identidade duvidosa).
2. Documento novo: insere com first_seen_at = last_seen_at = agora.
3. Documento já conhecido (mesmo hash, mesma quantidade de itens): substitui
   os itens pelo estado atual, preservando first_seen_at; last_seen_at = agora.
4. Mesmo hash com quantidade de itens diferente: BLOQUEIA (anomalia).
5. Mesmo documento SAP + empresa com hash diferente (ex.: a NF foi
   preenchida depois): substitui o registro antigo e preserva first_seen_at.
6. Um documento com mais de um hash no mesmo snapshot: BLOQUEIA.
7. Documento com itens cancelados e não cancelados ao mesmo tempo: BLOQUEIA.
8. Documento que sumiu do snapshot: vira MISSING (missing_since), mas só se a
   data do faturamento dele estiver entre as datas do snapshot atual.
   CANCELLED nunca vira MISSING.

STATUS
-------------------------------------------------------------------------------
ACTIVE     presente no snapshot.
CANCELLED  coluna "cancelado" preenchida (número do documento de estorno).
MISSING    existia, mas sumiu de um snapshot que cobria a data dele.


AUDITORIA
-------------------------------------------------------------------------------
Toda execução (sucesso ou falha) grava em etl_execution_log. Ao final, um
SELECT devolve o resumo para o app registrar no log da tarefa.
===============================================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_stg_reconcile_zfiglm_48b_bronze;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_stg_reconcile_zfiglm_48b_bronze()
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
    DECLARE v_scope_dates INT DEFAULT 0;
    DECLARE v_staging_hashes INT DEFAULT 0;
    DECLARE v_multi_hash_documents INT DEFAULT 0;
    DECLARE v_mixed_status_hashes INT DEFAULT 0;
    DECLARE v_count_mismatch_hashes INT DEFAULT 0;
    DECLARE v_existing_hashes INT DEFAULT 0;
    DECLARE v_rekeyed_hashes INT DEFAULT 0;
    DECLARE v_new_hashes INT DEFAULT 0;
    DECLARE v_deleted_rows INT DEFAULT 0;
    DECLARE v_inserted_rows INT DEFAULT 0;
    DECLARE v_new_rows INT DEFAULT 0;
    DECLARE v_cancelled_rows INT DEFAULT 0;
    DECLARE v_missing_updated INT DEFAULT 0;


    -- ------------------------------------------------------------------
    -- 2. ERRO: ROLLBACK + LOG FAILED + devolve o erro original
    -- ------------------------------------------------------------------
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_48b_scope_dates;
        DROP TEMPORARY TABLE IF EXISTS tmp_48b_stg_summary;
        DROP TEMPORARY TABLE IF EXISTS tmp_48b_doc_prev;

        SET v_finished_at = NOW();

        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name, source_table, target_table, execution_status,
            executed_by, started_at, finished_at, source_rows, selected_rows,
            inserted_rows, updated_rows, rejected_rows, error_code,
            error_message, audit_details, execution_duration_seconds
        )
        VALUES (
            'sp_stg_reconcile_zfiglm_48b_bronze',
            'stg_zfiglm_48b_overdue',
            'bronze_zfiglm_48b_overdue',
            'FAILED',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_staging_hashes,
            0,
            0,
            v_invalid_identity_rows + v_multi_hash_documents
                + v_mixed_status_hashes + v_count_mismatch_hashes,
            v_error_code,
            v_error_message,
            JSON_OBJECT(
                'scope_dates', v_scope_dates,
                'staging_hashes', v_staging_hashes,
                'invalid_identity_rows', v_invalid_identity_rows,
                'multi_hash_documents', v_multi_hash_documents,
                'mixed_status_hashes', v_mixed_status_hashes,
                'count_mismatch_hashes', v_count_mismatch_hashes
            ),
            TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
        );

        RESIGNAL;
    END;


    -- ------------------------------------------------------------------
    -- 3. STAGING COM DADOS
    -- ------------------------------------------------------------------
    SELECT COUNT(*) INTO v_source_rows
    FROM bp_datalake.stg_zfiglm_48b_overdue;

    IF v_source_rows = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: staging vazia.';
    END IF;


    -- ------------------------------------------------------------------
    -- 4. HASH DO DOCUMENTO (mesma fórmula do script de migração 03)
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.stg_zfiglm_48b_overdue
    SET reconciliation_hash = UNHEX(MD5(CONCAT_WS(
        '|',
        TRIM(numero_de_documento_do_sap),
        TRIM(empresa),
        TRIM(COALESCE(numero_da_nf, '')),
        TRIM(data_do_faturamento)
    )))
    WHERE reconciliation_hash IS NULL;


    -- ------------------------------------------------------------------
    -- 5. IDENTIDADE OBRIGATÓRIA (NF pode vir vazia; o resto não)
    -- ------------------------------------------------------------------
    SELECT COUNT(*) INTO v_invalid_identity_rows
    FROM bp_datalake.stg_zfiglm_48b_overdue
    WHERE TRIM(COALESCE(numero_de_documento_do_sap, '')) = ''
       OR TRIM(COALESCE(empresa, '')) = ''
       OR TRIM(COALESCE(data_do_faturamento, '')) = '';

    IF v_invalid_identity_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: linhas sem documento SAP, empresa ou data do faturamento.';
    END IF;


    START TRANSACTION;


    -- ------------------------------------------------------------------
    -- 6. DATAS DO SNAPSHOT (universo do MISSING)
    -- ------------------------------------------------------------------
    DROP TEMPORARY TABLE IF EXISTS tmp_48b_scope_dates;
    CREATE TEMPORARY TABLE tmp_48b_scope_dates (
        data_do_faturamento VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
        PRIMARY KEY (data_do_faturamento)
    );

    INSERT INTO tmp_48b_scope_dates
    SELECT DISTINCT LEFT(TRIM(data_do_faturamento), 10)
    FROM bp_datalake.stg_zfiglm_48b_overdue;

    SELECT COUNT(*) INTO v_scope_dates FROM tmp_48b_scope_dates;


    -- ------------------------------------------------------------------
    -- 7. UMA LINHA POR DOCUMENTO DO SNAPSHOT
    -- ------------------------------------------------------------------
    DROP TEMPORARY TABLE IF EXISTS tmp_48b_stg_summary;
    CREATE TEMPORARY TABLE tmp_48b_stg_summary (
        reconciliation_hash BINARY(16) NOT NULL,
        numero_de_documento_do_sap VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
        empresa VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
        item_count INT NOT NULL,
        cancelled_count INT NOT NULL,
        PRIMARY KEY (reconciliation_hash),
        INDEX idx_tmp_48b_document (numero_de_documento_do_sap, empresa)
    );

    INSERT INTO tmp_48b_stg_summary
    SELECT
        reconciliation_hash,
        -- Sem TRIM: igual ao valor gravado, para o JOIN usar o índice.
        MIN(numero_de_documento_do_sap),
        MIN(empresa),
        COUNT(*),
        SUM(CASE WHEN TRIM(COALESCE(cancelado, '')) <> '' THEN 1 ELSE 0 END)
    FROM bp_datalake.stg_zfiglm_48b_overdue
    GROUP BY reconciliation_hash;

    SELECT COUNT(*) INTO v_staging_hashes FROM tmp_48b_stg_summary;

    -- Regra 6: mesmo documento com duas NFs/datas no mesmo snapshot.
    SELECT COUNT(*) INTO v_multi_hash_documents
    FROM (
        SELECT numero_de_documento_do_sap, empresa
        FROM tmp_48b_stg_summary
        GROUP BY numero_de_documento_do_sap, empresa
        HAVING COUNT(*) > 1
    ) d;

    IF v_multi_hash_documents > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: documento SAP com mais de uma NF/data no mesmo snapshot.';
    END IF;

    -- Regra 7: itens cancelados e não cancelados no mesmo documento.
    SELECT COUNT(*) INTO v_mixed_status_hashes
    FROM tmp_48b_stg_summary
    WHERE cancelled_count > 0
      AND cancelled_count < item_count;

    IF v_mixed_status_hashes > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: documento com itens cancelados e ativos ao mesmo tempo.';
    END IF;


    -- ------------------------------------------------------------------
    -- 8. O QUE A BRONZE JÁ TEM DE CADA DOCUMENTO
    -- ------------------------------------------------------------------
    -- same_hash_rows = itens com o mesmo hash (regra 3/4);
    -- document_rows  = itens do mesmo documento SAP + empresa, qualquer hash
    --                  (regra 5);
    -- first_seen_at  = primeira aparição do documento, preservada.
    DROP TEMPORARY TABLE IF EXISTS tmp_48b_doc_prev;
    CREATE TEMPORARY TABLE tmp_48b_doc_prev (
        reconciliation_hash BINARY(16) NOT NULL,
        same_hash_rows INT NOT NULL,
        document_rows INT NOT NULL,
        first_seen_at DATETIME NULL,
        PRIMARY KEY (reconciliation_hash)
    );

    INSERT INTO tmp_48b_doc_prev
    SELECT
        s.reconciliation_hash,
        SUM(CASE WHEN b.reconciliation_hash = s.reconciliation_hash THEN 1 ELSE 0 END),
        COUNT(b.numero_de_documento_do_sap),
        MIN(b.first_seen_at)
    FROM tmp_48b_stg_summary s
    LEFT JOIN bp_datalake.bronze_zfiglm_48b_overdue b
        ON b.numero_de_documento_do_sap = s.numero_de_documento_do_sap
       AND b.empresa = s.empresa
    GROUP BY s.reconciliation_hash;

    -- Regra 4: mesmo documento, quantidade de itens diferente.
    SELECT COUNT(*) INTO v_count_mismatch_hashes
    FROM tmp_48b_doc_prev p
    INNER JOIN tmp_48b_stg_summary s
        ON s.reconciliation_hash = p.reconciliation_hash
    WHERE p.same_hash_rows > 0
      AND p.same_hash_rows <> s.item_count;

    IF v_count_mismatch_hashes > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: quantidade de itens diferente entre staging e Bronze.';
    END IF;

    SELECT
        COALESCE(SUM(same_hash_rows > 0), 0),
        COALESCE(SUM(same_hash_rows = 0 AND document_rows > 0), 0),
        COALESCE(SUM(document_rows = 0), 0)
    INTO v_existing_hashes, v_rekeyed_hashes, v_new_hashes
    FROM tmp_48b_doc_prev;


    -- ------------------------------------------------------------------
    -- 9. SUBSTITUIR OS DOCUMENTOS DO SNAPSHOT PELO ESTADO ATUAL
    -- ------------------------------------------------------------------
    DELETE b
    FROM bp_datalake.bronze_zfiglm_48b_overdue b
    INNER JOIN tmp_48b_stg_summary s
        ON b.numero_de_documento_do_sap = s.numero_de_documento_do_sap
       AND b.empresa = s.empresa;

    SET v_deleted_rows = ROW_COUNT();

    INSERT INTO bp_datalake.bronze_zfiglm_48b_overdue (
        empresa, modelo, numero_do_chassi, numero_da_nf, data_do_faturamento,
        grupo_dealer, ship_to_party_name, cliente, uf, condicao_de_pagamento,
        data_de_vencimento, quantos_dias_em_overdue, client_cnpj, valor_da_nf,
        pago, data_de_pagamento, data_de_emplacamento, codigo_do_cliente,
        credito, cancelado, status_overdue, valor_overdue, canal_de_vendas,
        detalhe_do_canal_de_vendas, aging, documento_de_faturamento,
        numero_de_documento_do_sap, year, byd_cnpj, key_reference,
        tipo_de_ordem, crm_sales_order,
        reference_date, dt_carga, id_execucao, source_file, usuario,
        reconciliation_hash, source_status, first_seen_at, last_seen_at,
        missing_since
    )
    SELECT
        s.empresa, s.modelo, s.numero_do_chassi, s.numero_da_nf, s.data_do_faturamento,
        s.grupo_dealer, s.ship_to_party_name, s.cliente, s.uf, s.condicao_de_pagamento,
        s.data_de_vencimento, s.quantos_dias_em_overdue, s.client_cnpj, s.valor_da_nf,
        s.pago, s.data_de_pagamento, s.data_de_emplacamento, s.codigo_do_cliente,
        s.credito, s.cancelado, s.status_overdue, s.valor_overdue, s.canal_de_vendas,
        s.detalhe_do_canal_de_vendas, s.aging, s.documento_de_faturamento,
        s.numero_de_documento_do_sap, s.year, s.byd_cnpj, s.key_reference,
        s.tipo_de_ordem, s.crm_sales_order,
        s.reference_date, s.dt_carga, s.id_execucao, s.source_file, s.usuario,
        s.reconciliation_hash,
        CASE WHEN TRIM(COALESCE(s.cancelado, '')) <> '' THEN 'CANCELLED' ELSE 'ACTIVE' END,
        COALESCE(p.first_seen_at, v_now),
        v_now,
        NULL
    FROM bp_datalake.stg_zfiglm_48b_overdue s
    INNER JOIN tmp_48b_doc_prev p
        ON p.reconciliation_hash = s.reconciliation_hash;

    SET v_inserted_rows = ROW_COUNT();

    -- Toda linha da staging tem que ter entrado (proteção contra JOIN errado).
    IF v_inserted_rows <> v_source_rows THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao ZFIGLM_48B bloqueada: linhas inseridas diferentes das linhas da staging.';
    END IF;

    SELECT
        COALESCE(SUM(CASE WHEN p.document_rows = 0 THEN s.item_count ELSE 0 END), 0),
        COALESCE(SUM(s.cancelled_count), 0)
    INTO v_new_rows, v_cancelled_rows
    FROM tmp_48b_stg_summary s
    INNER JOIN tmp_48b_doc_prev p
        ON p.reconciliation_hash = s.reconciliation_hash;


    -- ------------------------------------------------------------------
    -- 10. MISSING: sumiu de um snapshot que cobria a data dele
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.bronze_zfiglm_48b_overdue b
    INNER JOIN tmp_48b_scope_dates d
        ON d.data_do_faturamento = LEFT(TRIM(b.data_do_faturamento), 10)
    LEFT JOIN tmp_48b_stg_summary s
        ON s.reconciliation_hash = b.reconciliation_hash
    SET
        b.source_status = 'MISSING',
        b.missing_since = COALESCE(b.missing_since, v_now)
    WHERE s.reconciliation_hash IS NULL
      AND b.source_status = 'ACTIVE';

    SET v_missing_updated = ROW_COUNT();


    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_48b_scope_dates;
    DROP TEMPORARY TABLE IF EXISTS tmp_48b_stg_summary;
    DROP TEMPORARY TABLE IF EXISTS tmp_48b_doc_prev;

    SET v_finished_at = NOW();


    -- ------------------------------------------------------------------
    -- 11. LOG DE SUCESSO + RESUMO PARA O APP
    -- ------------------------------------------------------------------
    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name, source_table, target_table, execution_status,
        executed_by, started_at, finished_at, source_rows, selected_rows,
        inserted_rows, updated_rows, rejected_rows, error_code,
        error_message, audit_details, execution_duration_seconds
    )
    VALUES (
        'sp_stg_reconcile_zfiglm_48b_bronze',
        'stg_zfiglm_48b_overdue',
        'bronze_zfiglm_48b_overdue',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_staging_hashes,
        v_new_rows,
        (v_inserted_rows - v_new_rows) + v_missing_updated,
        0,
        NULL,
        NULL,
        JSON_OBJECT(
            'scope_dates', v_scope_dates,
            'staging_hashes', v_staging_hashes,
            'existing_hashes', v_existing_hashes,
            'rekeyed_hashes', v_rekeyed_hashes,
            'new_hashes', v_new_hashes,
            'deleted_rows', v_deleted_rows,
            'inserted_rows', v_inserted_rows,
            'new_rows', v_new_rows,
            'cancelled_rows', v_cancelled_rows,
            'missing_rows_updated', v_missing_updated
        ),
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
    );

    SET v_execution_id = LAST_INSERT_ID();

    SELECT
        v_execution_id AS execution_id,
        v_source_rows AS staging_rows,
        v_staging_hashes AS staging_documents,
        v_existing_hashes AS existing_documents,
        v_rekeyed_hashes AS rekeyed_documents,
        v_new_hashes AS new_documents,
        v_new_rows AS new_rows,
        v_inserted_rows AS inserted_rows,
        v_deleted_rows AS replaced_rows,
        v_cancelled_rows AS cancelled_rows,
        v_missing_updated AS missing_rows,
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at) AS duration_seconds;

END$$

DELIMITER ;
