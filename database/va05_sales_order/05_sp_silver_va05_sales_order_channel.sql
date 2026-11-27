/*
===============================================================================
PROCEDURE: sp_silver_va05_sales_order_channel(p_scope_start, p_scope_end)
===============================================================================

OBJETIVO
-------------------------------------------------------------------------------
Levar os itens da bronze_va05_sales_order para a
silver_va05_sales_order_channel: tipados e com o canal da ordem.
Roda logo depois da sp_stg_reconcile_va05_sales_order_bronze, com o mesmo
período.

    bronze_va05_sales_order --(data do documento no período)--> silver_va05_sales_order_channel


REGRA DO CANAL (Bruno, 27/11/2026, pedido do time CRM)
-------------------------------------------------------------------------------
Pelo usuário SAP que criou a ordem (criado_por):
    RFC_BRCRM           -> ONLINE_CRM       (pedido veio do CRM)
    outro RFC_*         -> OTHER_INTERFACE  (DMS, Mall, BSS...: grupo à parte)
    usuário pessoal     -> OFFLINE_MANUAL   (MXSD*, HQMM*...: criado à mão)
    vazio               -> UNKNOWN          (visível para investigar)


CONVERSÕES
-------------------------------------------------------------------------------
- Datas: o CSV traz AAAA-MM-DD. Fora desse formato vira NULL.
- Hora: HH:MM:SS. Fora do formato vira NULL.
- Números: formato do export (ex.: -1234.56). Fora do formato vira NULL.
Conversão protegida por REGEXP: em modo estrito, um STR_TO_DATE/CAST
inválido derrubaria o INSERT inteiro. O texto original fica na Bronze.


ESTRATÉGIA
-------------------------------------------------------------------------------
Numa transação: apaga da Silver as ordens com data do documento no período
e regrava a partir da Bronze (ACTIVE e MISSING). As outras datas não são
tocadas. Grava em etl_execution_log e devolve um resumo para o app.
===============================================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_va05_sales_order_channel;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_va05_sales_order_channel(
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
    DECLARE v_deleted_rows INT DEFAULT 0;
    DECLARE v_inserted_rows INT DEFAULT 0;


    -- ------------------------------------------------------------------
    -- 2. ERRO: ROLLBACK + LOG ERROR + devolve o erro original
    -- ------------------------------------------------------------------
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        SET v_finished_at = NOW();

        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name, source_table, target_table, execution_status,
            executed_by, started_at, finished_at, source_rows, selected_rows,
            inserted_rows, updated_rows, rejected_rows, error_code,
            error_message, audit_details, execution_duration_seconds
        )
        VALUES (
            'sp_silver_va05_sales_order_channel',
            'bronze_va05_sales_order',
            'silver_va05_sales_order_channel',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_source_rows,
            0,
            0,
            0,
            v_error_code,
            v_error_message,
            JSON_OBJECT('scope_start', p_scope_start, 'scope_end', p_scope_end),
            TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
        );

        RESIGNAL;
    END;


    -- ------------------------------------------------------------------
    -- 3. PARÂMETROS
    -- ------------------------------------------------------------------
    IF p_scope_start IS NULL OR p_scope_end IS NULL OR p_scope_start > p_scope_end THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Silver VA05 bloqueada: periodo da data do documento invalido.';
    END IF;

    SELECT COUNT(*) INTO v_source_rows
    FROM bp_datalake.bronze_va05_sales_order
    WHERE LEFT(data_do_documento, 10) BETWEEN p_scope_start AND p_scope_end;


    START TRANSACTION;


    -- ------------------------------------------------------------------
    -- 4. APAGA O PERÍODO DA SILVER
    -- ------------------------------------------------------------------
    DELETE FROM bp_datalake.silver_va05_sales_order_channel
    WHERE order_date BETWEEN p_scope_start AND p_scope_end;

    SET v_deleted_rows = ROW_COUNT();


    -- ------------------------------------------------------------------
    -- 5. REGRAVA A PARTIR DA BRONZE
    -- ------------------------------------------------------------------
    INSERT INTO bp_datalake.silver_va05_sales_order_channel (
        sales_order_number, sales_order_item, sales_order_type,
        sales_order_type_description, sd_document_category, order_date,
        order_time, created_on, customer_reference, header_customer_reference,
        created_by, order_channel,
        sales_organization, distribution_channel, division, sales_office,
        sales_group, plant_code, storage_location, shipping_point,
        sold_to_party, sold_to_name,
        material, material_description, order_quantity, confirmed_quantity,
        sales_unit, net_value_item, net_value_header, net_price, currency,
        overall_status, overall_status_description, item_overall_status,
        item_overall_status_description, delivery_status,
        delivery_status_description,
        source_status, first_seen_at, last_seen_at, silver_loaded_at
    )
    SELECT
        TRIM(b.documento_de_vendas),
        TRIM(b.item),
        NULLIF(TRIM(b.tipo_doc_vendas), ''),
        NULLIF(TRIM(b.descricao_do_tipo_de_documento_de_vendas), ''),
        NULLIF(TRIM(b.ctg_documento_sd), ''),

        CASE WHEN TRIM(b.data_do_documento) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
             THEN STR_TO_DATE(LEFT(TRIM(b.data_do_documento), 10), '%Y-%m-%d') END,
        CASE WHEN TRIM(b.hora_registro) REGEXP '^[0-9]{2}:[0-9]{2}:[0-9]{2}$'
             THEN CAST(TRIM(b.hora_registro) AS TIME) END,
        CASE WHEN TRIM(b.criado_em) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
             THEN STR_TO_DATE(LEFT(TRIM(b.criado_em), 10), '%Y-%m-%d') END,

        NULLIF(TRIM(b.referencia_de_cliente), ''),
        NULLIF(TRIM(b.referencia_de_cliente_cabecalho), ''),

        NULLIF(TRIM(b.criado_por), ''),
        -- Regra do canal (ver cabeçalho). O "\\_" faz o "_" ser literal no LIKE.
        CASE
            WHEN TRIM(COALESCE(b.criado_por, '')) = '' THEN 'UNKNOWN'
            WHEN UPPER(TRIM(b.criado_por)) = 'RFC_BRCRM' THEN 'ONLINE_CRM'
            WHEN UPPER(TRIM(b.criado_por)) LIKE 'RFC\\_%' THEN 'OTHER_INTERFACE'
            ELSE 'OFFLINE_MANUAL'
        END,

        NULLIF(TRIM(b.organizacao_de_vendas), ''),
        NULLIF(TRIM(b.canal_de_distribuicao), ''),
        NULLIF(TRIM(b.setor_de_atividade), ''),
        NULLIF(TRIM(b.escritorio_de_vendas), ''),
        NULLIF(TRIM(b.equipe_de_vendas), ''),
        NULLIF(TRIM(b.centro), ''),
        NULLIF(TRIM(b.deposito), ''),
        NULLIF(TRIM(b.local_expedicao_recebimento), ''),

        NULLIF(TRIM(b.emissor_da_ordem), ''),
        NULLIF(TRIM(b.nome_emissor_ordem), ''),

        NULLIF(TRIM(b.material), ''),
        NULLIF(TRIM(b.descricao_de_material), ''),
        CASE WHEN TRIM(b.quantidade_da_ordem_item) REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
             THEN CAST(TRIM(b.quantidade_da_ordem_item) AS DECIMAL(15, 3)) END,
        CASE WHEN TRIM(b.quantidade_confirmada_item) REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
             THEN CAST(TRIM(b.quantidade_confirmada_item) AS DECIMAL(15, 3)) END,
        NULLIF(TRIM(b.unidade_de_venda), ''),
        CASE WHEN TRIM(b.valor_liquido_item) REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
             THEN CAST(TRIM(b.valor_liquido_item) AS DECIMAL(18, 2)) END,
        CASE WHEN TRIM(b.valor_liquido_cabecalho) REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
             THEN CAST(TRIM(b.valor_liquido_cabecalho) AS DECIMAL(18, 2)) END,
        CASE WHEN TRIM(b.preco_liquido) REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
             THEN CAST(TRIM(b.preco_liquido) AS DECIMAL(18, 2)) END,
        NULLIF(TRIM(b.moeda_do_documento), ''),

        NULLIF(TRIM(b.status_global), ''),
        NULLIF(TRIM(b.descricao_de_status_global), ''),
        NULLIF(TRIM(b.item_de_status_global), ''),
        NULLIF(TRIM(b.descricao_de_item_de_status_global), ''),
        NULLIF(TRIM(b.status_global_remessa_todos_os_itens), ''),
        NULLIF(TRIM(b.descricao_de_status_global_da_remessa), ''),

        b.source_status,
        b.first_seen_at,
        b.last_seen_at,
        v_now
    FROM bp_datalake.bronze_va05_sales_order b
    WHERE LEFT(b.data_do_documento, 10) BETWEEN p_scope_start AND p_scope_end;

    SET v_inserted_rows = ROW_COUNT();

    COMMIT;

    SET v_finished_at = NOW();


    -- ------------------------------------------------------------------
    -- 6. LOG DE SUCESSO + RESUMO PARA O APP
    -- ------------------------------------------------------------------
    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name, source_table, target_table, execution_status,
        executed_by, started_at, finished_at, source_rows, selected_rows,
        inserted_rows, updated_rows, rejected_rows, error_code,
        error_message, audit_details, execution_duration_seconds
    )
    VALUES (
        'sp_silver_va05_sales_order_channel',
        'bronze_va05_sales_order',
        'silver_va05_sales_order_channel',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_source_rows,
        v_inserted_rows,
        0,
        0,
        NULL,
        NULL,
        JSON_OBJECT(
            'scope_start', p_scope_start,
            'scope_end', p_scope_end,
            'deleted_rows', v_deleted_rows,
            'inserted_rows', v_inserted_rows
        ),
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at)
    );

    SET v_execution_id = LAST_INSERT_ID();

    SELECT
        v_execution_id AS execution_id,
        v_source_rows AS bronze_rows,
        v_deleted_rows AS deleted_rows,
        v_inserted_rows AS inserted_rows,
        TIMESTAMPDIFF(SECOND, v_started_at, v_finished_at) AS duration_seconds;

END$$

DELIMITER ;
