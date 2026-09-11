/*
============================================================
ZSDBIL17 - GOLD
============================================================

Arquivo:
02_sp_gold_z17_load_base.sql

Objetivo:
Recriar integralmente a Gold de faturamento de veículos
a partir da Silver.

Origem:
    bp_datalake.silver_zsdbil17_outbound_movements

Destino:
    bp_datalake.gold_zsdbil17_faturamento_v2

============================================================
REGRA DA GOLD
============================================================

Granularidade:

    1 chassi = 1 linha

Fluxo:

    1. considerar somente:
           cfop_car = 'YES'

    2. rankear por chassi:

           issuance_date DESC
           invoice_number DESC
           id_bronze DESC

    3. selecionar somente o registro mais recente

    4. somente DEPOIS do ranking validar:
            invoice_number preenchido
           access_key_status = 'VALID'

           source_status IN (
               'ACTIVE',
               'UNKNOWN'
           )

           ship_to_party_code não pode iniciar com 'CBY'

============================================================
REGRA DE SOURCE_STATUS
============================================================

ACTIVE:
    Registro reconciliado e atualmente existente na origem.

UNKNOWN:
    Histórico anterior à implantação da reconciliação.
    Como esses registros não possuem classificação histórica
    confiável, continuam elegíveis quando a chave de acesso
    é válida.

CANCELLED:
    Não entra na Gold.

MISSING:
    Não entra na Gold.

MIXED:
    Não entra na Gold.

============================================================
REGRA DE SHIP-TO
============================================================

Códigos iniciados por 'CBY' representam entidades internas
e não devem compor a Gold de faturamento de veículos.

IMPORTANTE:

O filtro CBY é aplicado somente após o ranking.

Isso evita fallback para uma NF histórica antiga caso
o registro mais recente do chassi seja CBY.

============================================================
IMPORTANTE
============================================================

Não existe fallback para uma NF antiga.

Exemplo:

    NF100 -> ACTIVE / VALID / dealer externo
    NF250 -> ACTIVE / VALID / CBYDBR08

NF250 é o registro mais recente.

Resultado:

    o chassi NÃO entra na Gold.

============================================================
ESTRATÉGIA ATUAL
============================================================

FULL REFRESH TRANSACIONAL.

A Gold v2 é apagada e recriada a cada execução.

DELETE é utilizado em vez de TRUNCATE para permitir ROLLBACK.

============================================================
*/

DELIMITER $$


DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_load_base$$


CREATE PROCEDURE bp_datalake.sp_gold_z17_load_base()
BEGIN

    /*
    ============================================================
    01. VARIÁVEIS
    ============================================================
    */

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_finished_at DATETIME DEFAULT NULL;

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_vehicle_rows BIGINT DEFAULT 0;
    DECLARE v_latest_rows BIGINT DEFAULT 0;
    DECLARE v_selected_rows BIGINT DEFAULT 0;
    DECLARE v_rejected_rows BIGINT DEFAULT 0;
    DECLARE v_loaded_rows BIGINT DEFAULT 0;

    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    02. TRATAMENTO DE ERRO
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_gold_z17_latest;

        SET v_finished_at = NOW();

        IF v_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log

            SET
                execution_status = 'ERROR',

                finished_at = v_finished_at,

                source_rows = v_source_rows,

                selected_rows = v_selected_rows,

                inserted_rows = v_loaded_rows,

                updated_rows = 0,

                rejected_rows = v_rejected_rows,

                error_code = CONCAT(
                    'MYSQL ',
                    v_mysql_errno,
                    ' | SQLSTATE ',
                    v_sqlstate
                ),

                error_message = v_error_message,

                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        SECOND,
                        v_started_at,
                        v_finished_at
                    )

            WHERE id_execution = v_execution_id;

        END IF;

        RESIGNAL;

    END;


    /*
    ============================================================
    03. INÍCIO DA EXECUÇÃO
    ============================================================
    */

    SET v_started_at = NOW();


    INSERT INTO bp_datalake.etl_execution_log (

        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at

    )
    VALUES (

        'sp_gold_z17_load_base',

        'silver_zsdbil17_outbound_movements',

        'gold_zsdbil17_faturamento_v2',

        'RUNNING',

        CURRENT_USER(),

        v_started_at

    );


    SET v_execution_id = LAST_INSERT_ID();


    /*
    ============================================================
    04. CONTAGEM DA SILVER
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows

    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    05. PROTEÇÃO CONTRA SILVER VAZIA
    ============================================================
    */

    IF v_source_rows = 0 THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Carga Gold Z17 bloqueada: Silver vazia.';

    END IF;


    /*
    ============================================================
    06. INÍCIO DA TRANSAÇÃO
    ============================================================
    */

    START TRANSACTION;


    /*
    ============================================================
    07. CONTAGEM DOS REGISTROS CLASSIFICADOS COMO VEÍCULO
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_vehicle_rows

    FROM bp_datalake.silver_zsdbil17_outbound_movements

    WHERE
        cfop_car = 'YES'

        AND NULLIF(
            TRIM(chassis_serial_number),
            ''
        ) IS NOT NULL;


    /*
    ============================================================
    08. ÚLTIMO REGISTRO POR CHASSI
    ============================================================

    IMPORTANTE:

    source_status, access_key_status e ship_to_party_code
    NÃO são utilizados antes do ranking.

    Primeiro determinamos qual é o registro mais recente
    daquele chassi.

    Isso impede fallback para uma NF histórica antiga.
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_gold_z17_latest;


    CREATE TEMPORARY TABLE tmp_gold_z17_latest AS

    SELECT
        ranked.*

    FROM (

        SELECT
            s.*,

            ROW_NUMBER() OVER (

                PARTITION BY
                    TRIM(s.chassis_serial_number)

                ORDER BY
                    s.issuance_date DESC,
                    s.invoice_number DESC,
                    s.id_bronze DESC

            ) AS numero_linha

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        WHERE
            s.cfop_car = 'YES'

            AND NULLIF(
                TRIM(s.chassis_serial_number),
                ''
            ) IS NOT NULL

    ) AS ranked

    WHERE
        ranked.numero_linha = 1;


    /*
    ============================================================
    09. CONTAGEM DE CHASSIS APÓS RANKING
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_latest_rows

    FROM tmp_gold_z17_latest;


    /*
    ============================================================
    10. CONTAGEM DOS REGISTROS ELEGÍVEIS
    ============================================================

    Regras aplicadas somente após o ranking:

    - access_key_status = VALID
    - invoice_number preenchido
    - source_status = ACTIVE ou UNKNOWN
    - ship_to_party_code não pode iniciar com CBY

    ============================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows

    FROM tmp_gold_z17_latest

    WHERE
        access_key_status = 'VALID'

        AND NULLIF(
            TRIM(invoice_number),
            ''
        ) IS NOT NULL

        AND source_status IN (
            'ACTIVE',
            'UNKNOWN'
        )

        AND (
            ship_to_party_code IS NULL
            OR TRIM(ship_to_party_code) NOT LIKE 'CBY%'
        );

    /*
    Registros classificados como veículo e mais recentes
    por chassi, mas não elegíveis para a Gold.
    */

    SET v_rejected_rows =
        v_latest_rows - v_selected_rows;


    /*
    ============================================================
    11. LIMPEZA DA GOLD
    ============================================================
    */

    DELETE
    FROM bp_datalake.gold_zsdbil17_faturamento_v2;


    /*
    ============================================================
    12. CARGA SILVER -> GOLD
    ============================================================
    */

    INSERT INTO bp_datalake.gold_zsdbil17_faturamento_v2 (

        id_bronze,

        chassis_serial_number,
        invoice_number,
        issuance_date,

        material,
        description,
        descricao_do_produto,
        descricao_da_cor,

        manufacturing_year,
        model_year,

        total_amount,

        byd_cnpj_number,

        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,

        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,

        payment_condition,

        chave_de_acesso,
        ncm,
        cfop,

        plant_code,
        company_code,
        sales_order_type,
        division,

        sap_document,
        sales_order_number,
        invoice_series,

        no_do_motor,
        codigo_da_cor,

        potencia_motor,
        cap_trac_max,
        cilindradas_cc,
        distancia_entre_eixo,
        peso_liquido_ton,
        peso_bruto_ton,

        tipo_de_veiculo,
        especie_do_veiculo,
        tipo_do_combustivel,
        tipo_de_pintura,
        condicao_do_veiculo,

        cap_ocup_max,

        vin_condition,
        code_brand_mode,

        item_category,

        usuario,
        source_file,
        dt_carga_silver,
        dt_carga_gold,
        id_execucao

    )

    SELECT

        s.id_bronze,

        TRIM(s.chassis_serial_number),

        TRIM(s.invoice_number),

        s.issuance_date,

        NULLIF(
            TRIM(s.material),
            ''
        ),

        NULLIF(
            TRIM(s.description),
            ''
        ),

        NULLIF(
            TRIM(s.descricao_do_produto),
            ''
        ),

        NULLIF(
            TRIM(s.descricao_da_cor),
            ''
        ),

        s.manufacturing_year,

        s.model_year,

        s.total_amount,

        NULLIF(
            TRIM(s.byd_cnpj_number),
            ''
        ),

        NULLIF(
            TRIM(s.sold_to_party_code),
            ''
        ),

        NULLIF(
            TRIM(s.sold_to_party_cnpj),
            ''
        ),

        NULLIF(
            TRIM(s.sold_to_party_name),
            ''
        ),

        NULLIF(
            TRIM(s.sold_to_party_state),
            ''
        ),

        NULLIF(
            TRIM(s.ship_to_party_code),
            ''
        ),

        NULLIF(
            TRIM(s.ship_to_party_cnpj),
            ''
        ),

        NULLIF(
            TRIM(s.ship_to_party_name),
            ''
        ),

        NULLIF(
            TRIM(s.ship_to_party_state),
            ''
        ),

        NULLIF(
            TRIM(s.payment_condition),
            ''
        ),

        TRIM(s.chave_de_acesso),

        NULLIF(
            TRIM(s.ncm),
            ''
        ),

        NULLIF(
            TRIM(s.cfop),
            ''
        ),

        NULLIF(
            TRIM(s.plant_code),
            ''
        ),

        NULLIF(
            TRIM(s.company_code),
            ''
        ),

        NULLIF(
            TRIM(s.sales_order_type),
            ''
        ),

        NULLIF(
            TRIM(s.division),
            ''
        ),

        NULLIF(
            TRIM(s.sap_document),
            ''
        ),

        NULLIF(
            TRIM(s.sales_order_number),
            ''
        ),

        NULLIF(
            TRIM(s.invoice_series),
            ''
        ),

        NULLIF(
            TRIM(s.no_do_motor),
            ''
        ),

        NULLIF(
            TRIM(s.codigo_da_cor),
            ''
        ),

        s.potencia_motor,

        s.cap_trac_max,

        s.cilindradas_cc,

        s.distancia_entre_eixo,

        s.peso_liquido_ton,

        s.peso_bruto_ton,

        NULLIF(
            TRIM(s.tipo_de_veiculo),
            ''
        ),

        NULLIF(
            TRIM(s.especie_do_veiculo),
            ''
        ),

        NULLIF(
            TRIM(s.tipo_do_combustivel),
            ''
        ),

        NULLIF(
            TRIM(s.tipo_de_pintura),
            ''
        ),

        NULLIF(
            TRIM(s.condicao_do_veiculo),
            ''
        ),

        s.cap_ocup_max,

        NULLIF(
            TRIM(s.vin_condition),
            ''
        ),

        NULLIF(
            TRIM(s.code_brand_mode),
            ''
        ),

        NULLIF(
            TRIM(s.item_category),
            ''
        ),

        CURRENT_USER(),

        NULLIF(
            TRIM(s.source_file),
            ''
        ),

        s.dt_carga,

        NOW(),

        v_execution_id

   FROM tmp_gold_z17_latest AS s

    WHERE
        s.access_key_status = 'VALID'

        AND NULLIF(
            TRIM(s.invoice_number),
            ''
        ) IS NOT NULL

        AND s.source_status IN (
            'ACTIVE',
            'UNKNOWN'
        )

        AND (
            s.ship_to_party_code IS NULL
            OR TRIM(s.ship_to_party_code) NOT LIKE 'CBY%'
        );


    SET v_loaded_rows = ROW_COUNT();


    /*
    ============================================================
    13. VALIDAÇÃO DE CONSISTÊNCIA
    ============================================================
    */

    IF v_loaded_rows <> v_selected_rows THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Carga Gold Z17 bloqueada: quantidade carregada diferente da quantidade selecionada.';

    END IF;


    /*
    ============================================================
    14. LIMPEZA DA ÁREA TEMPORÁRIA
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_gold_z17_latest;


    /*
    ============================================================
    15. CONFIRMAÇÃO DA TRANSAÇÃO
    ============================================================
    */

    COMMIT;


    /*
    ============================================================
    16. FINALIZAÇÃO DA AUDITORIA
    ============================================================
    */

    SET v_finished_at = NOW();


    UPDATE bp_datalake.etl_execution_log

    SET
        execution_status = 'SUCCESS',

        finished_at = v_finished_at,

        source_rows = v_source_rows,

        selected_rows = v_selected_rows,

        inserted_rows = v_loaded_rows,

        updated_rows = 0,

        rejected_rows = v_rejected_rows,

        error_code = NULL,

        error_message = NULL,

        execution_duration_seconds =
            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            )

    WHERE id_execution = v_execution_id;


    /*
    ============================================================
    17. RETORNO DA EXECUÇÃO
    ============================================================
    */

    SELECT

        v_execution_id AS execution_id,

        'SUCCESS' AS execution_status,

        v_started_at AS started_at,

        v_finished_at AS finished_at,

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        ) AS execution_duration_seconds,

        v_source_rows AS source_rows,

        v_vehicle_rows AS vehicle_rows,

        v_latest_rows AS latest_vehicle_chassis,

        v_selected_rows AS selected_rows,

        v_rejected_rows AS rejected_rows,

        v_loaded_rows AS loaded_rows,

        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_faturamento_v2

        ) AS gold_rows;


END$$


DELIMITER ;
