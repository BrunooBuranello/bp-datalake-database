DROP PROCEDURE IF EXISTS bp_datalake.sp_process_zsdbil17_pipeline;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_process_zsdbil17_pipeline()
BEGIN

    DECLARE v_pipeline_execution_id BIGINT DEFAULT NULL;
    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    =========================================================
    TRATAMENTO DE ERRO DA PIPELINE
    =========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        SET v_finished_at = NOW(6);

        IF v_pipeline_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,

                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        MICROSECOND,
                        v_started_at,
                        v_finished_at
                    ) / 1000000,

                error_code = v_error_code,
                error_message = v_error_message

            WHERE id_execution = v_pipeline_execution_id;

        END IF;

        RESIGNAL;

    END;


    /*
    =========================================================
    1. INÍCIO
    =========================================================
    */

    SET v_started_at = NOW(6);


    /*
    =========================================================
    2. REGISTRA INÍCIO DA PIPELINE
    =========================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        created_at
    )
    VALUES (
        'sp_process_zsdbil17_pipeline',
        'stg_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_pipeline_execution_id = LAST_INSERT_ID();


    /*
    =========================================================
    3. STAGING -> BRONZE
    =========================================================
    */

    CALL bp_datalake.sp_stg_reconcile_zsdbil17_bronze();


    /*
    =========================================================
    4. SILVER - LOAD BASE
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_load_base();


    /*
    =========================================================
    5. SILVER - NORMALIZAÇÃO
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_normalize();


    /*
    =========================================================
    6. SILVER - VALIDAÇÃO DA CHAVE DE ACESSO
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_access_keys();


    /*
    =========================================================
    7. SILVER - CLASSIFICAÇÃO CFOP
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_cfop();


    /*
    =========================================================
    8. SILVER - TIPO DE VENDA
    =========================================================

    Enriquecimento histórico da Silver.

    Preenche:
        division_description_enriched

    Prioridade:
        1. Division
        2. CFOP como fallback
        3. UNKNOWN

    Deve executar após o CFOP porque utiliza essa informação
    como fallback da classificação.
    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_sales_type();

    /*
    =========================================================
    9. SILVER - CLASSIFICAÇÃO DO TIPO DE VEÍCULO
    =========================================================

    Enriquecimento da Silver por código de material.

    Fontes:
        dim_zsdbil17_material_exclusion
        material_master

    Destino:
        vehicle_type_code

    Prioridade:
        1. Material na exclusão -> BUS_TRUCK
        2. Material na master   -> CAR
        3. Sem correspondência  -> UNKNOWN

    A execução ocorre antes do carregamento da Gold para
    permitir a aplicação do filtro de elegibilidade.

    =========================================================
    */

    CALL bp_datalake.sp_silver_z17_vehicle_type();

    /*
    =========================================================
    9. GOLD - LOAD BASE
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_load_base();


    /*
    =========================================================
    10. GOLD - TIPO DE VENDA
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_sales_type();


    /*
    =========================================================
    11. GOLD - ENRIQUECIMENTOS
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_enrich();


    /*
    =========================================================
    12. GOLD - DIRECT SALES
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_direct_sales();


    /*
    =========================================================
    13. GOLD - APPEND LEGACY 2024/2025
    =========================================================

    O histórico Legacy entra somente após o processamento
    completo da Gold atual.

    A procedure Legacy é APPEND ONLY e não altera registros
    CURRENT já existentes na Gold.

    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_append_legacy_2024_2025();


    /*
    =========================================================
    14. GOLD - ENRIQUECIMENTO DE MODELO
    =========================================================

    Origem:
        bp_datalake.material_master

    Chave:
        material -> cod_sap

    Destino:
        model_simplified

    A execução ocorre após o Legacy para garantir que
    registros CURRENT e LEGACY recebam o enriquecimento.

    Registros sem correspondência recebem UNKNOWN.

    A procedure é idempotente e possui controle próprio
    no etl_execution_log.
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_enrich_model();


    /*
    =========================================================
    15. DEMO HISTORY - SINCRONIZAÇÃO
    =========================================================

    Fonte histórica:
        silver_zsdbil17_outbound_movements

    A execução ocorre somente após o processamento completo
    da Silver e Gold.

    Responsabilidades:
        - identificar novos ciclos DEMO;
        - adicionar novas movimentações do chassi;
        - atualizar status OPEN / WARNING / OVERDUE / CLOSED;
        - preservar o histórico já registrado.

    A procedure é idempotente:
        reexecuções não duplicam eventos já existentes.
    =========================================================
    */

    CALL bp_datalake.sp_sync_gold_zsdbil17_demo_history();


    /*
    =========================================================
    16. DEMO HISTORY - ENRIQUECIMENTO DEALER
    =========================================================

    Origem:
        bronze.mapping_dealer_expansion

    Chave:
        ship_to_party_code -> sap_code

    Destinos:
        dealer_group
        brand_dealer

    Regra:
        - utiliza o mapeamento atual do dealer;
        - aplica a mesma prioridade utilizada na Gold principal;
        - registros sem correspondência recebem UNKNOWN;
        - não altera regras do ciclo DEMO;
        - não altera campos operacionais do BP.
    =========================================================
    */

    CALL bp_datalake.sp_gold_z17_demo_enrich_dealer();


    /*
    =========================================================
    17. FINALIZA PIPELINE
    =========================================================
    */

    SET v_finished_at = NOW(6);

    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,

        execution_duration_seconds =
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,

        error_code = NULL,
        error_message = NULL

    WHERE id_execution = v_pipeline_execution_id;


    /*
    =========================================================
    18. RETORNO FINAL
    =========================================================
    */

    SELECT
        v_pipeline_execution_id AS pipeline_execution_id,

        'SUCCESS' AS execution_status,

        'gold_zsdbil17_faturamento' AS target_table,

        v_started_at AS started_at,

        v_finished_at AS finished_at,

        ROUND(
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
            2
        ) AS execution_duration_seconds;


END$$

DELIMITER ;
