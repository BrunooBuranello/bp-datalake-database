/*
===============================================================================
PROCEDURE: sp_stg_reconcile_fbl5n_bronze(p_scope_start, p_scope_end)
===============================================================================

OBJETIVO
-------------------------------------------------------------------------------
Reconciliar a foto da FBL5N que o app grava na stg_fbl5n com o histórico da
bronze_fbl5n, sem duplicar. Mesmo desenho da
sp_stg_reconcile_zfiglm_48b_bronze (ADR-036) e da Z17; ADR-043 do
sap_service.

    SAP (FBL5N, layout /BRUNO_FBL5N) -> CSV -> stg_fbl5n (TRUNCATE + INSERT)
                                                  |
                                                  | reconciliation_hash
                                                  v
                                   sp_stg_reconcile_fbl5n_bronze
                                                  |
                                                  v
                                   bronze_fbl5n (uma linha por partida)


PARÂMETROS
-------------------------------------------------------------------------------
p_scope_start / p_scope_end ('AAAA-MM-DD'): período de LANÇAMENTO pedido ao
SAP nesta execução. É o universo do MISSING: só some quem tinha data de
lançamento dentro do período pedido.


CHAVE DE RECONCILIAÇÃO
-------------------------------------------------------------------------------
reconciliation_hash = MD5(empresa | no_documento | ano do lançamento | item)
guardado como BINARY(16). Identifica a PARTIDA (uma linha): na FBL5N o item
faz parte da chave, então o hash é único (validado em 63.019 linhas de
jan/2026 e 10.034 de out/2026: 0 repetidas). O ano vem da data de lançamento
porque o layout não exporta o exercício (na BYD o exercício é o ano civil).

Fora da chave, de propósito: compensação (doc_compensacao,
data_de_compensacao), atribuição, texto, vencimento etc. Mudam depois do
lançamento e são atualizados a cada execução que cobre a partida.


REGRAS
-------------------------------------------------------------------------------
1. Staging vazia: BLOQUEIA.
2. Rodapé de total do SAP (linha só com montante, sem empresa, documento,
   item e data): NÃO vira partida. É o total de controle: a soma das partidas
   tem que bater com um dos rodapés (tolerância 0,01). Não bateu: BLOQUEIA.
3. Linha que não é rodapé e não tem empresa, documento, item ou data:
   BLOQUEIA (identidade duvidosa).
4. Montante fora do formato numérico do export (ex.: -1234.56): BLOQUEIA.
5. Partida com data de lançamento fora do período pedido: BLOQUEIA (o
   MISSING ficaria errado).
6. Mesma partida (hash) duas vezes no snapshot: BLOQUEIA.
7. Partida nova: insere com first_seen_at = last_seen_at = agora.
8. Partida conhecida: substitui pelo estado atual (compensação etc.),
   preservando first_seen_at; last_seen_at = agora; volta a ACTIVE.
9. Partida ACTIVE da Bronze com lançamento no período pedido que sumiu do
   snapshot: vira MISSING (missing_since). Nunca é apagada.


AUDITORIA
-------------------------------------------------------------------------------
Toda execução (sucesso ou falha) grava em etl_execution_log, com o total de
controle do rodapé em audit_details. Ao final, um SELECT devolve o resumo
para o app registrar no log da tarefa.
===============================================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_stg_reconcile_fbl5n_bronze;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_stg_reconcile_fbl5n_bronze(
    -- Collation igual à das tabelas (o padrão do banco é 0900_ai_ci):
    -- evita "Illegal mix of collations" ao comparar com data_de_lancamento.
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
    DECLARE v_footer_rows INT DEFAULT 0;
    DECLARE v_item_rows INT DEFAULT 0;
    DECLARE v_invalid_identity_rows INT DEFAULT 0;
    DECLARE v_invalid_amount_rows INT DEFAULT 0;
    DECLARE v_out_of_scope_rows INT DEFAULT 0;
    DECLARE v_duplicate_hashes INT DEFAULT 0;
    DECLARE v_items_total DECIMAL(20, 2) DEFAULT 0;
    DECLARE v_footer_matches INT DEFAULT 0;
    DECLARE v_footer_total DECIMAL(20, 2) DEFAULT NULL;
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

        DROP TEMPORARY TABLE IF EXISTS tmp_fbl5n_prev;

        SET v_finished_at = NOW();

        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name, source_table, target_table, execution_status,
            executed_by, started_at, finished_at, source_rows, selected_rows,
            inserted_rows, updated_rows, rejected_rows, error_code,
            error_message, audit_details, execution_duration_seconds
        )
        VALUES (
            'sp_stg_reconcile_fbl5n_bronze',
            'stg_fbl5n',
            'bronze_fbl5n',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_item_rows,
            0,
            0,
            v_invalid_identity_rows + v_invalid_amount_rows
                + v_out_of_scope_rows + v_duplicate_hashes,
            v_error_code,
            v_error_message,
            JSON_OBJECT(
                'scope_start', p_scope_start,
                'scope_end', p_scope_end,
                'footer_rows', v_footer_rows,
                'items_total', v_items_total,
                'invalid_identity_rows', v_invalid_identity_rows,
                'invalid_amount_rows', v_invalid_amount_rows,
                'out_of_scope_rows', v_out_of_scope_rows,
                'duplicate_hashes', v_duplicate_hashes
            ),
            TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
        );

        RESIGNAL;
    END;


    -- ------------------------------------------------------------------
    -- 3. PARÂMETROS E STAGING COM DADOS
    -- ------------------------------------------------------------------
    IF p_scope_start IS NULL OR p_scope_end IS NULL OR p_scope_start > p_scope_end THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: periodo de lancamento invalido.';
    END IF;

    SELECT COUNT(*) INTO v_source_rows FROM bp_datalake.stg_fbl5n;

    IF v_source_rows = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: staging vazia.';
    END IF;


    -- ------------------------------------------------------------------
    -- 4. RODAPÉ x PARTIDA
    -- ------------------------------------------------------------------
    -- Rodapé = total do SAP: só o montante preenchido nas colunas de
    -- identidade. Fica na staging (nada é descartado), mas não vira partida.
    SELECT
        COALESCE(SUM(is_footer), 0),
        COALESCE(SUM(1 - is_footer), 0)
    INTO v_footer_rows, v_item_rows
    FROM (
        SELECT CASE
            WHEN TRIM(COALESCE(empresa, '')) = ''
             AND TRIM(COALESCE(no_documento, '')) = ''
             AND TRIM(COALESCE(item, '')) = ''
             AND TRIM(COALESCE(data_de_lancamento, '')) = ''
             AND TRIM(COALESCE(montante_em_moeda_interna, '')) <> ''
            THEN 1 ELSE 0 END AS is_footer
        FROM bp_datalake.stg_fbl5n
    ) f;

    -- Regra 3: identidade obrigatória nas partidas.
    SELECT COUNT(*) INTO v_invalid_identity_rows
    FROM bp_datalake.stg_fbl5n
    WHERE NOT (
            TRIM(COALESCE(empresa, '')) = ''
        AND TRIM(COALESCE(no_documento, '')) = ''
        AND TRIM(COALESCE(item, '')) = ''
        AND TRIM(COALESCE(data_de_lancamento, '')) = ''
        AND TRIM(COALESCE(montante_em_moeda_interna, '')) <> ''
    )
      AND (
            TRIM(COALESCE(empresa, '')) = ''
         OR TRIM(COALESCE(no_documento, '')) = ''
         OR TRIM(COALESCE(item, '')) = ''
         OR TRIM(COALESCE(data_de_lancamento, '')) = ''
      );

    IF v_invalid_identity_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: partidas sem empresa, documento, item ou data de lancamento.';
    END IF;

    -- Regra 4: montante numérico (formato do export: -1234.56).
    SELECT COUNT(*) INTO v_invalid_amount_rows
    FROM bp_datalake.stg_fbl5n
    WHERE TRIM(COALESCE(montante_em_moeda_interna, '')) <> ''
      AND TRIM(montante_em_moeda_interna) NOT REGEXP '^-?[0-9]+(\\.[0-9]+)?$';

    IF v_invalid_amount_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: montante fora do formato numerico.';
    END IF;

    -- Regra 5: partida fora do período pedido.
    SELECT COUNT(*) INTO v_out_of_scope_rows
    FROM bp_datalake.stg_fbl5n
    WHERE TRIM(COALESCE(empresa, '')) <> ''
      AND (LEFT(TRIM(data_de_lancamento), 10) < p_scope_start
        OR LEFT(TRIM(data_de_lancamento), 10) > p_scope_end);

    IF v_out_of_scope_rows > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: partidas com lancamento fora do periodo pedido.';
    END IF;

    -- Regra 2: total de controle. Sem rodapé (ex.: export sem totais) a
    -- carga segue e o log mostra footer_rows = 0.
    SELECT COALESCE(SUM(CAST(TRIM(montante_em_moeda_interna) AS DECIMAL(20, 2))), 0)
    INTO v_items_total
    FROM bp_datalake.stg_fbl5n
    WHERE TRIM(COALESCE(empresa, '')) <> '';

    IF v_footer_rows > 0 THEN
        SELECT COUNT(*), MAX(CAST(TRIM(montante_em_moeda_interna) AS DECIMAL(20, 2)))
        INTO v_footer_matches, v_footer_total
        FROM bp_datalake.stg_fbl5n
        WHERE TRIM(COALESCE(empresa, '')) = ''
          AND TRIM(COALESCE(montante_em_moeda_interna, '')) <> ''
          AND ABS(CAST(TRIM(montante_em_moeda_interna) AS DECIMAL(20, 2)) - v_items_total) <= 0.01;

        IF v_footer_matches = 0 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: soma das partidas diferente do total do rodape do SAP.';
        END IF;
    END IF;


    -- ------------------------------------------------------------------
    -- 5. HASH DA PARTIDA
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.stg_fbl5n
    SET reconciliation_hash = UNHEX(MD5(CONCAT_WS(
        '|',
        TRIM(empresa),
        TRIM(no_documento),
        LEFT(TRIM(data_de_lancamento), 4),
        TRIM(item)
    )))
    WHERE TRIM(COALESCE(empresa, '')) <> '';

    -- Regra 6: partida repetida no mesmo snapshot.
    SELECT COUNT(*) INTO v_duplicate_hashes
    FROM (
        SELECT reconciliation_hash
        FROM bp_datalake.stg_fbl5n
        WHERE reconciliation_hash IS NOT NULL
        GROUP BY reconciliation_hash
        HAVING COUNT(*) > 1
    ) d;

    IF v_duplicate_hashes > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: mesma partida (empresa, documento, ano, item) repetida no snapshot.';
    END IF;


    START TRANSACTION;


    -- ------------------------------------------------------------------
    -- 6. O QUE A BRONZE JÁ TEM (first_seen_at preservado)
    -- ------------------------------------------------------------------
    DROP TEMPORARY TABLE IF EXISTS tmp_fbl5n_prev;
    CREATE TEMPORARY TABLE tmp_fbl5n_prev (
        reconciliation_hash BINARY(16) NOT NULL,
        first_seen_at DATETIME NOT NULL,
        PRIMARY KEY (reconciliation_hash)
    );

    INSERT INTO tmp_fbl5n_prev
    SELECT b.reconciliation_hash, b.first_seen_at
    FROM bp_datalake.bronze_fbl5n b
    INNER JOIN bp_datalake.stg_fbl5n s
        ON s.reconciliation_hash = b.reconciliation_hash;

    SET v_existing_rows = ROW_COUNT();
    SET v_new_rows = v_item_rows - v_existing_rows;


    -- ------------------------------------------------------------------
    -- 7. SUBSTITUIR AS PARTIDAS DO SNAPSHOT PELO ESTADO ATUAL
    -- ------------------------------------------------------------------
    DELETE b
    FROM bp_datalake.bronze_fbl5n b
    INNER JOIN tmp_fbl5n_prev p
        ON p.reconciliation_hash = b.reconciliation_hash;

    SET v_deleted_rows = ROW_COUNT();

    INSERT INTO bp_datalake.bronze_fbl5n (
        empresa, loc_negocios, conta, chave_referencia_3, referencia,
        data_de_lancamento, vencimento_liquido, item, tipo_de_documento,
        montante_em_moeda_interna, cod_razao_especial, texto, no_documento,
        doc_faturamento, atribuicao, doc_compensacao, data_de_compensacao,
        conta_do_razao, frmpgto, condicoes_pgto, solicitacao_de_l_c,
        scope_start, scope_end, dt_carga, id_execucao, source_file, usuario,
        reconciliation_hash, source_status, first_seen_at, last_seen_at,
        missing_since
    )
    SELECT
        s.empresa, s.loc_negocios, s.conta, s.chave_referencia_3, s.referencia,
        s.data_de_lancamento, s.vencimento_liquido, s.item, s.tipo_de_documento,
        s.montante_em_moeda_interna, s.cod_razao_especial, s.texto, s.no_documento,
        s.doc_faturamento, s.atribuicao, s.doc_compensacao, s.data_de_compensacao,
        s.conta_do_razao, s.frmpgto, s.condicoes_pgto, s.solicitacao_de_l_c,
        s.scope_start, s.scope_end, s.dt_carga, s.id_execucao, s.source_file, s.usuario,
        s.reconciliation_hash,
        'ACTIVE',
        COALESCE(p.first_seen_at, v_now),
        v_now,
        NULL
    FROM bp_datalake.stg_fbl5n s
    LEFT JOIN tmp_fbl5n_prev p
        ON p.reconciliation_hash = s.reconciliation_hash
    WHERE s.reconciliation_hash IS NOT NULL;

    SET v_inserted_rows = ROW_COUNT();

    -- Toda partida da staging tem que ter entrado (proteção contra JOIN errado).
    IF v_inserted_rows <> v_item_rows THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Reconciliacao FBL5N bloqueada: partidas inseridas diferentes das partidas da staging.';
    END IF;


    -- ------------------------------------------------------------------
    -- 8. MISSING: sumiu de um snapshot que cobria a data de lançamento
    -- ------------------------------------------------------------------
    UPDATE bp_datalake.bronze_fbl5n b
    LEFT JOIN bp_datalake.stg_fbl5n s
        ON s.reconciliation_hash = b.reconciliation_hash
    SET
        b.source_status = 'MISSING',
        b.missing_since = COALESCE(b.missing_since, v_now)
    WHERE s.reconciliation_hash IS NULL
      AND b.source_status = 'ACTIVE'
      AND LEFT(b.data_de_lancamento, 10) BETWEEN p_scope_start AND p_scope_end;

    SET v_missing_updated = ROW_COUNT();


    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_fbl5n_prev;

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
        'sp_stg_reconcile_fbl5n_bronze',
        'stg_fbl5n',
        'bronze_fbl5n',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_item_rows,
        v_new_rows,
        v_existing_rows + v_missing_updated,
        0,
        NULL,
        NULL,
        JSON_OBJECT(
            'scope_start', p_scope_start,
            'scope_end', p_scope_end,
            'footer_rows', v_footer_rows,
            'footer_total', v_footer_total,
            'items_total', v_items_total,
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
        v_item_rows AS item_rows,
        v_footer_rows AS footer_rows,
        v_footer_total AS footer_total,
        v_items_total AS items_total,
        v_new_rows AS new_rows,
        v_existing_rows AS existing_rows,
        v_inserted_rows AS inserted_rows,
        v_missing_updated AS missing_rows,
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at) AS duration_seconds;

END$$

DELIMITER ;
