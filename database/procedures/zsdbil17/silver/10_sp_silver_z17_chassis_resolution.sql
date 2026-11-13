/*
============================================================
ZSDBIL17 - SILVER
10 - RESOLUÇÃO DO CHASSI (sp_silver_z17_chassis_resolution)
============================================================

Objetivo (ADR-016 do sap_service):
O SAP às vezes manda a NF de carro com "Chassis / Serial Number"
vazio e o chassi em outra coluna da MESMA linha ("Chassi do
Veiculo" ou "Customer Reference"). Como a Gold só aceita linha com
chassi, esses carros sumiam do faturamento sem aviso (ex.: ZFC1 NF
273913 de 10/11/2026). Esta procedure decide, linha a linha e com
regras explícitas, de onde vem o chassi; o que nenhuma regra
resolve vai para silver_zsdbil17_chassis_fallback.

Pré-requisitos na pipeline (rodar depois de):
    sp_silver_z17_cfop                    (cfop_car)
    sp_silver_z17_vehicle_type            (classificação de 09/11)
    sp_refresh_dim_material_classification (tipo do material)

Regras (a primeira que servir decide), só para linhas pendentes:

    R0  chassi preenchido pelo SAP          -> SAP_CHASSIS
    RT  CFOP de venda, sem ordem de venda, sem VF01 e valor do
        item 0 (NF só de imposto, ex.: complemento de ICMS-ST)
                                            -> TAX_COMPLEMENT
    R1  material BUS_TRUCK                  -> NOT_CAR_BUS_TRUCK
    R2  material PART                       -> NOT_CAR_PART
        (o VIN da linha é o do veículo onde a peça vai)
        material OTHER                      -> NOT_CAR_OTHER
    R3  material CAR + grupo SAP B1 (peça) na linha + CFOP de venda
                                            -> FALLBACK_MATERIAL_GROUP_CONFLICT
    R4a carro + CFOP de venda + VINs diferentes nas duas colunas
                                            -> FALLBACK_VIN_CONFLICT
    R4b carro + CFOP de venda + VIN em "Chassi do Veiculo"
                                            -> CHASSI_DO_VEICULO (preenche)
    R4c carro + CFOP de venda + VIN só em "Customer Reference"
                                            -> CUSTOMER_REFERENCE (preenche)
    R4d carro + CFOP de venda sem VIN nenhum
                                            -> FALLBACK_VEHICLE_WITHOUT_VIN
    R6  carro fora do CFOP de venda (entradas, retornos,
        transferências)                     -> CAR_NOT_SALE
    R5  material sem classificação + grupo SAP G1 (veículo)
        + CFOP de venda                     -> FALLBACK_VEHICLE_MATERIAL_NOT_REGISTERED
    R7  material sem classificação + VIN + CFOP de venda
                                            -> FALLBACK_MATERIAL_UNCLASSIFIED
    R8  demais                              -> NO_CHASSIS_EXPECTED

VIN aceito: exatamente 17 caracteres, só A-Z (sem I, O, Q) e 0-9,
com comparação SENSÍVEL a maiúsculas (REGEXP_LIKE com 'c'; a
collation _ci deixaria passar minúsculas).

Linhas pendentes:
    chassis_rule IS NULL      (novas ou recarregadas pela carga
                               incremental, que apaga e recarrega
                               as datas da staging)
    chassis_rule FALLBACK_*   (reavaliadas a cada execução: um
                               material cadastrado depois resolve
                               o caso sozinho)
Linhas já resolvidas não são reavaliadas. Mudou a classificação de
um material já decidido? Zere chassis_rule dessas linhas (mesma
regra do sp_silver_z17_vehicle_type).

A Bronze não é alterada. Na Silver, chassis_serial_number passa a
ter o chassi resolvido e chassis_source diz de onde ele veio.

Fallback (só casos abertos):
    - apaga o que deixou de ser FALLBACK_*;
    - insere o que é novo (first_seen_at = agora);
    - atualiza o que continua aberto (last_seen_at = agora).

============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_chassis_resolution;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_z17_chassis_resolution()
BEGIN

    DECLARE v_execution_id BIGINT DEFAULT NULL;
    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_pending_rows BIGINT DEFAULT 0;
    DECLARE v_filled_rows BIGINT DEFAULT 0;
    DECLARE v_open_fallback BIGINT DEFAULT 0;
    DECLARE v_new_fallback BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ========================================================
    TRATAMENTO DE ERROS
    ========================================================
    Desfaz a transação, registra o erro e propaga para a
    pipeline (que também registra e interrompe).
    ========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        IF v_execution_id IS NOT NULL THEN
            UPDATE bp_datalake.etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = NOW(6),
                error_code = v_error_code,
                error_message = v_error_message
            WHERE id_execution = v_execution_id;
        END IF;

        RESIGNAL;
    END;


    /*
    ========================================================
    1. INÍCIO + LOG
    ========================================================
    */

    SET v_started_at = NOW(6);

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at
    )
    VALUES (
        'sp_silver_z17_chassis_resolution',
        'silver_zsdbil17_outbound_movements',
        'silver_zsdbil17_chassis_fallback',
        'RUNNING',
        CURRENT_USER(),
        v_started_at
    );

    SET v_execution_id = LAST_INSERT_ID();


    SELECT COUNT(*)
    INTO v_pending_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE chassis_rule IS NULL
       OR chassis_rule LIKE 'FALLBACK\_%';


    START TRANSACTION;


    /*
    ========================================================
    2. DECIDE A REGRA DE CADA LINHA PENDENTE
    ========================================================
    Um único UPDATE com CASE: a ordem dos WHEN é a ordem das
    regras. O tipo do material vem da dim_material_classification
    (LEFT JOIN: sem linha = material sem classificação).
    ========================================================
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s
    LEFT JOIN bp_datalake.dim_material_classification AS d
        ON d.material = TRIM(s.material)
    SET s.chassis_rule =
        CASE

            -- R0
            WHEN NULLIF(TRIM(s.chassis_serial_number), '') IS NOT NULL
                THEN 'SAP_CHASSIS'

            -- RT
            WHEN s.cfop_car = 'YES'
             AND NULLIF(TRIM(s.sales_order_number), '') IS NULL
             AND NULLIF(TRIM(s.billing_number_vf01), '') IS NULL
             AND COALESCE(s.item_total_net_price, 0) = 0
                THEN 'TAX_COMPLEMENT'

            -- R1 / R2
            WHEN d.material_type = 'BUS_TRUCK' THEN 'NOT_CAR_BUS_TRUCK'
            WHEN d.material_type = 'PART'      THEN 'NOT_CAR_PART'
            WHEN d.material_type = 'OTHER'     THEN 'NOT_CAR_OTHER'

            -- R3
            WHEN d.material_type = 'CAR'
             AND s.cfop_car = 'YES'
             AND TRIM(s.material_group_2) = 'B1'
                THEN 'FALLBACK_MATERIAL_GROUP_CONFLICT'

            -- R4a
            WHEN d.material_type = 'CAR'
             AND s.cfop_car = 'YES'
             AND REGEXP_LIKE(TRIM(COALESCE(s.chassi_do_veiculo, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
             AND REGEXP_LIKE(TRIM(COALESCE(s.customer_reference, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
             AND TRIM(s.chassi_do_veiculo) <> TRIM(s.customer_reference)
                THEN 'FALLBACK_VIN_CONFLICT'

            -- R4b
            WHEN d.material_type = 'CAR'
             AND s.cfop_car = 'YES'
             AND REGEXP_LIKE(TRIM(COALESCE(s.chassi_do_veiculo, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
                THEN 'CHASSI_DO_VEICULO'

            -- R4c
            WHEN d.material_type = 'CAR'
             AND s.cfop_car = 'YES'
             AND REGEXP_LIKE(TRIM(COALESCE(s.customer_reference, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
                THEN 'CUSTOMER_REFERENCE'

            -- R4d
            WHEN d.material_type = 'CAR'
             AND s.cfop_car = 'YES'
                THEN 'FALLBACK_VEHICLE_WITHOUT_VIN'

            -- R6
            WHEN d.material_type = 'CAR'
                THEN 'CAR_NOT_SALE'

            -- R5
            WHEN d.material_type IS NULL
             AND s.cfop_car = 'YES'
             AND TRIM(s.material_group_2) = 'G1'
                THEN 'FALLBACK_VEHICLE_MATERIAL_NOT_REGISTERED'

            -- R7
            WHEN d.material_type IS NULL
             AND s.cfop_car = 'YES'
             AND (
                    REGEXP_LIKE(TRIM(COALESCE(s.chassi_do_veiculo, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
                 OR REGEXP_LIKE(TRIM(COALESCE(s.customer_reference, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
                 )
                THEN 'FALLBACK_MATERIAL_UNCLASSIFIED'

            -- R8
            ELSE 'NO_CHASSIS_EXPECTED'

        END
    WHERE s.chassis_rule IS NULL
       OR s.chassis_rule LIKE 'FALLBACK\_%';


    /*
    ========================================================
    3. PREENCHE O CHASSI DAS LINHAS RESOLVIDAS
    ========================================================
    chassis_source IS NULL garante que só linhas recém-decididas
    são tocadas (as já resolvidas não voltam a ser pendentes).
    ========================================================
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements
    SET chassis_source = 'SAP'
    WHERE chassis_rule = 'SAP_CHASSIS'
      AND chassis_source IS NULL;

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements
    SET
        chassis_serial_number = TRIM(chassi_do_veiculo),
        chassis_source = 'CHASSI_DO_VEICULO'
    WHERE chassis_rule = 'CHASSI_DO_VEICULO'
      AND chassis_source IS NULL;

    SET v_filled_rows = ROW_COUNT();

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements
    SET
        chassis_serial_number = TRIM(customer_reference),
        chassis_source = 'CUSTOMER_REFERENCE'
    WHERE chassis_rule = 'CUSTOMER_REFERENCE'
      AND chassis_source IS NULL;

    SET v_filled_rows = v_filled_rows + ROW_COUNT();


    /*
    ========================================================
    4. FALLBACK: SÓ CASOS ABERTOS
    ========================================================
    */

    -- 4.1 Remove o que foi resolvido (ou cuja linha não existe mais).
    DELETE f
    FROM bp_datalake.silver_zsdbil17_chassis_fallback AS f
    LEFT JOIN bp_datalake.silver_zsdbil17_outbound_movements AS s
        ON s.id_bronze = f.id_bronze
       AND s.chassis_rule LIKE 'FALLBACK\_%'
    WHERE s.id_bronze IS NULL;

    -- 4.2 Insere os novos e atualiza os que continuam abertos.
    --     LEFT() respeita o tamanho das colunas da fallback.
    INSERT INTO bp_datalake.silver_zsdbil17_chassis_fallback (
        id_bronze,
        invoice_number,
        issuance_date,
        plant_code,
        so_item,
        sales_order_type,
        cfop,
        material,
        description,
        material_type,
        material_group_2,
        sales_order_number,
        billing_number_vf01,
        item_total_net_price,
        chassis_serial_number,
        chassi_do_veiculo,
        customer_reference,
        fallback_reason,
        source_file,
        first_seen_at,
        last_seen_at
    )
    SELECT
        x.id_bronze,
        x.invoice_number,
        x.issuance_date,
        x.plant_code,
        x.so_item,
        x.sales_order_type,
        x.cfop,
        x.material,
        x.description,
        x.material_type,
        x.material_group_2,
        x.sales_order_number,
        x.billing_number_vf01,
        x.item_total_net_price,
        x.chassis_serial_number,
        x.chassi_do_veiculo,
        x.customer_reference,
        x.fallback_reason,
        x.source_file,
        v_started_at,
        v_started_at
    FROM (
        SELECT
            s.id_bronze,
            LEFT(TRIM(s.invoice_number), 50)          AS invoice_number,
            s.issuance_date,
            LEFT(TRIM(s.plant_code), 10)              AS plant_code,
            LEFT(TRIM(s.so_item), 20)                 AS so_item,
            LEFT(TRIM(s.sales_order_type), 10)        AS sales_order_type,
            LEFT(TRIM(s.cfop), 10)                    AS cfop,
            LEFT(TRIM(s.material), 50)                AS material,
            LEFT(TRIM(s.description), 255)            AS description,
            d.material_type,
            LEFT(TRIM(s.material_group_2), 10)        AS material_group_2,
            LEFT(TRIM(s.sales_order_number), 20)      AS sales_order_number,
            LEFT(TRIM(s.billing_number_vf01), 20)     AS billing_number_vf01,
            s.item_total_net_price,
            LEFT(TRIM(s.chassis_serial_number), 100)  AS chassis_serial_number,
            LEFT(TRIM(s.chassi_do_veiculo), 100)      AS chassi_do_veiculo,
            LEFT(TRIM(s.customer_reference), 100)     AS customer_reference,
            s.chassis_rule                            AS fallback_reason,
            LEFT(s.source_file, 255)                  AS source_file
        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s
        LEFT JOIN bp_datalake.dim_material_classification AS d
            ON d.material = TRIM(s.material)
        WHERE s.chassis_rule LIKE 'FALLBACK\_%'
    ) AS x
    ON DUPLICATE KEY UPDATE
        fallback_reason = x.fallback_reason,
        material_type = x.material_type,
        source_file = x.source_file,
        last_seen_at = v_started_at;


    SELECT
        COUNT(*),
        COUNT(CASE WHEN first_seen_at = v_started_at THEN 1 END)
    INTO
        v_open_fallback,
        v_new_fallback
    FROM bp_datalake.silver_zsdbil17_chassis_fallback;


    COMMIT;


    /*
    ========================================================
    5. LOG FINAL
    ========================================================
    source_rows   = linhas pendentes avaliadas
    updated_rows  = chassis preenchidos por R4b/R4c
    rejected_rows = casos abertos na fallback
    selected_rows = casos novos na fallback (alarme da Fase 2)
    ========================================================
    */

    SET v_finished_at = NOW(6);

    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,
        source_rows = v_pending_rows,
        selected_rows = v_new_fallback,
        inserted_rows = 0,
        updated_rows = v_filled_rows,
        rejected_rows = v_open_fallback,
        error_code = NULL,
        error_message = NULL,
        execution_duration_seconds =
            TIMESTAMPDIFF(MICROSECOND, v_started_at, v_finished_at) / 1000000
    WHERE id_execution = v_execution_id;

END $$

DELIMITER ;
