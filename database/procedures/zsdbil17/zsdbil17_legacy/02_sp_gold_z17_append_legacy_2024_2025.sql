/*
============================================================
ZSDBIL17 - GOLD - APPEND LEGACY 2024/2025
============================================================

Procedure:
sp_gold_z17_append_legacy_2024_2025

Origem:
bp_datalake.silver_invoiced_legacy_2024_2025

Destino:
bp_datalake.gold_zsdbil17_faturamento

REGRAS:

- APPEND ONLY
- Não apaga registros da Gold
- Não altera registros CURRENT
- 1 chassi = 1 linha
- cfop_car = 'YES'
- Gold existente sempre tem prioridade
- access_key_status não bloqueia o Legacy
- record_source = 'LEGACY_2024_2025'
- Reexecução não duplica registros

Desempate Legacy:
1. issuance_date DESC
2. dt_carga DESC
3. invoice_number DESC
4. id DESC

============================================================
*/


DROP PROCEDURE IF EXISTS
    bp_datalake.sp_gold_z17_append_legacy_2024_2025;


DELIMITER $$


CREATE PROCEDURE
    bp_datalake.sp_gold_z17_append_legacy_2024_2025()
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
    DECLARE v_selected_rows BIGINT DEFAULT 0;
    DECLARE v_inserted_rows BIGINT DEFAULT 0;

    DECLARE v_duplicate_legacy BIGINT DEFAULT 0;
    DECLARE v_overlap_current BIGINT DEFAULT 0;

    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    02. ERROR HANDLER
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS
            tmp_gold_z17_legacy_selected;

        SET v_finished_at = NOW();


        IF v_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log

            SET
                execution_status = 'ERROR',

                finished_at = v_finished_at,

                source_rows = v_source_rows,

                selected_rows = v_selected_rows,

                inserted_rows = v_inserted_rows,

                updated_rows = 0,

                rejected_rows =
                    v_source_rows - v_selected_rows,

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
    03. INÍCIO
    ============================================================
    */

    SET v_started_at = NOW();


    /*
    ============================================================
    04. LOG DA EXECUÇÃO
    ============================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (

        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at

    )
    VALUES (

        'sp_gold_z17_append_legacy_2024_2025',

        'silver_invoiced_legacy_2024_2025',

        'gold_zsdbil17_faturamento',

        'RUNNING',

        CURRENT_USER(),

        v_started_at

    );


    SET v_execution_id = LAST_INSERT_ID();


    /*
    ============================================================
    05. TOTAL DA SILVER LEGACY
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows

    FROM bp_datalake.silver_invoiced_legacy_2024_2025;


    IF v_source_rows = 0 THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Append Legacy bloqueado: Silver Legacy vazia.';

    END IF;


    /*
    ============================================================
    06. INÍCIO DA TRANSAÇÃO
    ============================================================
    */

    START TRANSACTION;


    /*
    ============================================================
    07. SELECIONA 1 REGISTRO POR CHASSI
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS
        tmp_gold_z17_legacy_selected;


    CREATE TEMPORARY TABLE
        tmp_gold_z17_legacy_selected
    AS

    SELECT
        ranked.id AS legacy_id,
        ranked.chassis_serial_number

    FROM (

        SELECT
            l.id,

            TRIM(
                l.chassis_serial_number
            ) AS chassis_serial_number,

            ROW_NUMBER() OVER (

                PARTITION BY
                    TRIM(l.chassis_serial_number)

                ORDER BY
                    l.issuance_date DESC,
                    l.dt_carga DESC,
                    l.invoice_number DESC,
                    l.id DESC

            ) AS numero_linha

        FROM
            bp_datalake.silver_invoiced_legacy_2024_2025 AS l

        WHERE

            NULLIF(
                TRIM(l.chassis_serial_number),
                ''
            ) IS NOT NULL

            AND l.cfop_car = 'YES'

    ) AS ranked

    WHERE

        ranked.numero_linha = 1

        AND NOT EXISTS (

            SELECT 1

            FROM
                bp_datalake.gold_zsdbil17_faturamento AS g

            WHERE

                TRIM(g.chassis_serial_number)
                    COLLATE utf8mb4_unicode_ci

                =

                ranked.chassis_serial_number
                    COLLATE utf8mb4_unicode_ci

        );


    /*
    ============================================================
    08. PRIMARY KEY TEMPORÁRIA

    Não criamos índice no chassis_serial_number porque
    a coluna de origem Legacy é TEXT.
    ============================================================
    */

    ALTER TABLE tmp_gold_z17_legacy_selected
        ADD PRIMARY KEY (legacy_id);


    /*
    ============================================================
    09. QUANTIDADE SELECIONADA
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows

    FROM tmp_gold_z17_legacy_selected;


    /*
    ============================================================
    10. APPEND LEGACY -> GOLD
    ============================================================
    */

    INSERT INTO bp_datalake.gold_zsdbil17_faturamento (

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
        division_description,

        sap_document,
        sales_order_number,

        billing_number_vf01,

        iva,

        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,

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

        store_name_crm,
        dealer_group,
        brand_dealer,

        payment_condition_description_dim,
        plant_description,

        origem_chassi,

        usuario,
        source_file,

        dt_carga_silver,
        dt_carga_gold,

        id_execucao,

        record_source

    )

    SELECT

        /*
        ========================================================
        ID LEGACY
        ========================================================
        */

        l.id,


        /*
        CHASSI / FATURAMENTO
        */

        TRIM(l.chassis_serial_number),

        TRIM(l.invoice_number),

        DATE(l.issuance_date),


        /*
        MATERIAL
        */

        NULLIF(
            TRIM(l.material),
            ''
        ),


        /*
        DESCRIÇÕES
        */

        NULLIF(
            TRIM(l.description),
            ''
        ),

        NULLIF(
            TRIM(l.descricao_do_produto),
            ''
        ),

        NULLIF(
            TRIM(l.descricao_da_cor),
            ''
        ),


        /*
        ANOS
        */

        l.manufacturing_year,

        l.model_year,


        /*
        VALOR
        */

        NULLIF(
            TRIM(l.total_amount),
            ''
        ),


        /*
        CNPJ BYD
        */

        NULLIF(
            TRIM(l.byd_cnpj_number),
            ''
        ),


        /*
        SOLD TO
        */

        NULLIF(
            TRIM(l.sold_to_party_code),
            ''
        ),

        NULLIF(
            TRIM(l.sold_to_party_cnpj),
            ''
        ),

        NULLIF(
            TRIM(l.sold_to_party_name),
            ''
        ),

        NULLIF(
            TRIM(l.sold_to_party_state),
            ''
        ),


        /*
        SHIP TO
        */

        NULLIF(
            TRIM(l.ship_to_party_code),
            ''
        ),

        NULLIF(
            TRIM(l.ship_to_party_cnpj),
            ''
        ),

        NULLIF(
            TRIM(l.ship_to_party_name),
            ''
        ),

        NULLIF(
            TRIM(l.ship_to_party_state),
            ''
        ),


        /*
        PAGAMENTO
        */

        NULLIF(
            TRIM(l.payment_condition),
            ''
        ),


        /*
        FISCAL
        */

        NULLIF(
            TRIM(l.chave_de_acesso),
            ''
        ),

        NULLIF(
            TRIM(l.ncm),
            ''
        ),

        NULLIF(
            TRIM(l.cfop),
            ''
        ),


        /*
        ORGANIZAÇÃO SAP
        */

        NULLIF(
            TRIM(l.plant_code),
            ''
        ),

        NULLIF(
            TRIM(l.company_code),
            ''
        ),

        NULLIF(
            TRIM(l.sales_order_type),
            ''
        ),

        NULLIF(
            TRIM(l.division),
            ''
        ),

        NULLIF(
            TRIM(l.division_description),
            ''
        ),


        /*
        DOCUMENTOS SAP
        */

        NULLIF(
            TRIM(l.sap_document),
            ''
        ),

        NULLIF(
            TRIM(l.sales_order_number),
            ''
        ),

        NULLIF(
            TRIM(l.billing_number_vf01),
            ''
        ),


        /*
        DIREITO FISCAL
        */

        NULLIF(
            TRIM(l.iva),
            ''
        ),

        NULLIF(
            TRIM(l.dir_fiscal_icms),
            ''
        ),

        NULLIF(
            TRIM(l.dir_fiscal_ipi),
            ''
        ),

        NULLIF(
            TRIM(l.dir_fiscal_iss),
            ''
        ),

        NULLIF(
            TRIM(l.dir_fiscal_cofins),
            ''
        ),

        NULLIF(
            TRIM(l.dir_fiscal_pis),
            ''
        ),


        /*
        SÉRIE
        */

        NULLIF(
            TRIM(l.invoice_series),
            ''
        ),


        /*
        DADOS TÉCNICOS
        */

        NULLIF(
            TRIM(l.no_do_motor),
            ''
        ),

        NULLIF(
            TRIM(l.codigo_da_cor),
            ''
        ),

        l.potencia_motor,

        l.cap_trac_max,

        l.cilindradas_cc,

        l.distancia_entre_eixo,

        l.peso_liquido_ton,

        l.peso_bruto_ton,

        NULLIF(
            TRIM(l.tipo_de_veiculo),
            ''
        ),

        NULLIF(
            TRIM(l.especie_do_veiculo),
            ''
        ),

        NULLIF(
            TRIM(l.tipo_do_combustivel),
            ''
        ),

        NULLIF(
            TRIM(l.tipo_de_pintura),
            ''
        ),

        NULLIF(
            TRIM(l.condicao_do_veiculo),
            ''
        ),

        l.cap_ocup_max,

        NULLIF(
            TRIM(l.vin_condition),
            ''
        ),

        NULLIF(
            TRIM(l.code_brand_mode),
            ''
        ),

        NULLIF(
            TRIM(l.item_category),
            ''
        ),


        /*
        DEALER LEGACY
        */

        NULLIF(
            TRIM(l.dealer_store),
            ''
        ),

        NULLIF(
            TRIM(l.dealer_group),
            ''
        ),

        NULL,


        /*
        CAMPOS SEM FONTE LEGACY CONFIÁVEL
        */

        NULL,

        NULL,


        /*
        ORIGEM DO CHASSI
        */

        CASE

            WHEN TRIM(l.chassis_serial_number)
                 REGEXP '^[A-Za-z]'
            THEN 'Importado'

            WHEN TRIM(l.chassis_serial_number)
                 REGEXP '^[0-9]'
            THEN 'Nacional'

            ELSE NULL

        END,


        /*
        AUDITORIA
        */

        COALESCE(
            NULLIF(TRIM(l.usuario), ''),
            'LEGACY_2024_2025'
        ),

        NULLIF(
            TRIM(l.source_file),
            ''
        ),

        l.dt_carga,

        NOW(),

        v_execution_id,

        'LEGACY_2024_2025'


    FROM
        tmp_gold_z17_legacy_selected AS t

    INNER JOIN
        bp_datalake.silver_invoiced_legacy_2024_2025 AS l

        ON l.id = t.legacy_id;


    SET v_inserted_rows = ROW_COUNT();


    /*
    ============================================================
    11. VALIDAÇÃO DA QUANTIDADE
    ============================================================
    */

    IF v_inserted_rows <> v_selected_rows THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Append Legacy bloqueado: quantidade inserida diferente da selecionada.';

    END IF;


    /*
    ============================================================
    12. VALIDA DUPLICIDADE DENTRO DO LEGACY
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_duplicate_legacy

    FROM (

        SELECT
            chassis_serial_number

        FROM
            bp_datalake.gold_zsdbil17_faturamento

        WHERE
            record_source = 'LEGACY_2024_2025'

        GROUP BY
            chassis_serial_number

        HAVING COUNT(*) > 1

    ) AS duplicated;


    IF v_duplicate_legacy > 0 THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Append Legacy bloqueado: chassis duplicados encontrados dentro do Legacy.';

    END IF;


    /*
    ============================================================
    13. VALIDA OVERLAP LEGACY X CURRENT
    ============================================================
    */

    SELECT
        COUNT(DISTINCT legacy.chassis_serial_number)

    INTO
        v_overlap_current

    FROM
        bp_datalake.gold_zsdbil17_faturamento AS legacy

    INNER JOIN
        bp_datalake.gold_zsdbil17_faturamento AS current_data

        ON
            TRIM(legacy.chassis_serial_number)
                COLLATE utf8mb4_unicode_ci

            =

            TRIM(current_data.chassis_serial_number)
                COLLATE utf8mb4_unicode_ci

    WHERE
        legacy.record_source = 'LEGACY_2024_2025'

        AND current_data.record_source <> 'LEGACY_2024_2025';


    IF v_overlap_current > 0 THEN

        SIGNAL SQLSTATE '45000'

        SET MESSAGE_TEXT =
            'Append Legacy bloqueado: chassis Legacy também encontrados no CURRENT.';

    END IF;


    /*
    ============================================================
    14. LIMPEZA TEMPORÁRIA
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS
        tmp_gold_z17_legacy_selected;


    /*
    ============================================================
    15. COMMIT
    ============================================================
    */

    COMMIT;


    /*
    ============================================================
    16. FINALIZA LOG
    ============================================================
    */

    SET v_finished_at = NOW();


    UPDATE bp_datalake.etl_execution_log

    SET
        execution_status = 'SUCCESS',

        finished_at = v_finished_at,

        source_rows = v_source_rows,

        selected_rows = v_selected_rows,

        inserted_rows = v_inserted_rows,

        updated_rows = 0,

        rejected_rows =
            v_source_rows - v_selected_rows,

        error_code = NULL,

        error_message = NULL,

        execution_duration_seconds =
            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            )

    WHERE
        id_execution = v_execution_id;


    /*
    ============================================================
    17. RETORNO
    ============================================================
    */

    SELECT

        v_execution_id
            AS execution_id,

        'SUCCESS'
            AS execution_status,

        v_source_rows
            AS legacy_source_rows,

        v_selected_rows
            AS legacy_selected_rows,

        v_inserted_rows
            AS legacy_inserted_rows,

        v_duplicate_legacy
            AS duplicate_legacy_chassis,

        v_overlap_current
            AS overlap_current_chassis,

        (
            SELECT COUNT(*)

            FROM
                bp_datalake.gold_zsdbil17_faturamento

            WHERE
                record_source = 'LEGACY_2024_2025'

        ) AS total_legacy_gold,

        (
            SELECT COUNT(*)

            FROM
                bp_datalake.gold_zsdbil17_faturamento

        ) AS total_gold_rows,

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        ) AS execution_duration_seconds;


END$$


DELIMITER ;
