/*
============================================================
INVOICED LEGACY 2024/2025 - SILVER
============================================================

Procedure:
sp_silver_invoiced_legacy_2024_2025_standardize

Objetivo:
- Consolidar Bronze 2024 + Bronze 2025
- Carregar silver_invoiced_legacy_2024_2025
- Aplicar padronizações iniciais

IMPORTANTE:
Esta procedure altera SOMENTE:
bp_datalake.silver_invoiced_legacy_2024_2025

============================================================
*/


DELIMITER $$


DROP PROCEDURE IF EXISTS
    bp_datalake.sp_silver_invoiced_legacy_2024_2025_standardize$$


CREATE PROCEDURE
    bp_datalake.sp_silver_invoiced_legacy_2024_2025_standardize()
BEGIN

    DECLARE v_rows_2024 BIGINT DEFAULT 0;
    DECLARE v_rows_2025 BIGINT DEFAULT 0;
    DECLARE v_total_rows BIGINT DEFAULT 0;


    /*
    ============================================================
    01. LIMPEZA DA SILVER LEGACY
    ============================================================
    */

    DELETE
    FROM bp_datalake.silver_invoiced_legacy_2024_2025;


    /*
    ============================================================
    02. CARGA LEGACY 2024
    ============================================================
    */

    INSERT INTO bp_datalake.silver_invoiced_legacy_2024_2025 (

        chassis_serial_number,
        chassi_validation,
        sap_document,
        company_code,
        plant_code,
        sales_order_number,
        sales_order_type,
        item_category,
        delivery_note_number_picking,
        billing_number_vf01,
        invoice_number,
        issuance_date,
        status_doc,
        estornado,
        so_item,
        material,
        ncm,
        origin,
        utiliz_material,
        description,
        chassis_serial_number_1,
        cfop,
        qty,
        total_amount,
        cb_icms,
        icms_percentual,
        icms_amount,
        cb_icms_st,
        st_percentual,
        icms_st_amount,
        cb_ipi,
        ipi_percentual,
        ipi_amount,
        cb_pis,
        pis_percentual,
        pis_amount,
        cb_cofins,
        cofins_percentual,
        cofins_amount,
        difal_percentual,
        difal,
        commission_percentual_ra04,
        commission_amount,
        msrp_pr10,
        discont_percentual_ra06,
        sharing_icms_percentual_ra05,
        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,
        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,
        payment_condition,
        transportation_code,
        transportation_cnpj,
        transportation_name,
        transportation_state,
        iva,
        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,
        chave_de_acesso,
        model,
        model_material_code,
        `key`,
        `month`,
        `year`,
        canceled_bp,
        bp_status,
        check_model,
        dealer_store,
        dealer_group,
        port,
        sales_type,
        check_return_db,
        licensed,
        dt_carga,
        source_file,
        usuario

    )

    SELECT

        chassis_serial_number,
        chassi_validation,
        sap_document,
        company_code,
        plant_code,
        sales_order_number,
        sales_order_type,

        item_categoy,

        delivery_note_number_picking,
        billing_number_vf01,
        invoice_number,
        issuance_date,
        status_doc,
        estornado,
        so_item,
        material,
        ncm,
        origin,
        utiliz_material,
        description,
        chassis_serial_number_1,
        cfop,
        qty,
        total_amount,
        cb_icms,
        icms_percentual,
        icms_amount,
        cb_icms_st,
        st_percentual,
        icms_st_amount,
        cb_ipi,
        ipi_percentual,
        ipi_amount,
        cb_pis,
        pis_percentual,
        pis_amount,
        cb_cofins,
        cofins_percentual,
        cofins_amount,
        difal_percentual,
        difal,
        commission_percentual_ra04,
        commission_amount,
        msrp_pr10,
        discont_percentual_ra06,
        sharing_icms_percentual_ra05,
        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,
        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,
        payment_condition,
        transportation_code,
        transportation_cnpj,
        transportation_name,
        transportation_state,
        iva,
        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,
        chave_de_acesso,
        model,
        model_material_code,
        `key`,
        `month`,
        `year`,
        canceled_bp,
        bp_status,
        check_model,
        dealer_store,
        dealer_group,
        port,
        sales_type,
        check_return_db,
        licensed,
        dt_carga,
        source_file,
        usuario

    FROM bp_datalake.bronze_invoiced_database_2024;


    SET v_rows_2024 = ROW_COUNT();


    /*
    ============================================================
    03. CARGA LEGACY 2025
    ============================================================
    */

    INSERT INTO bp_datalake.silver_invoiced_legacy_2024_2025 (

        chassis_serial_number,
        chassi_validation,
        sap_document,
        company_code,
        plant_code,
        sales_order_number,
        sales_order_type,
        item_category,
        delivery_note_number_picking,
        billing_number_vf01,
        invoice_number,
        issuance_date,
        status_doc,
        estornado,
        so_item,
        material,
        ncm,
        origin,
        utiliz_material,
        description,
        chassis_serial_number_1,
        cfop,
        qty,
        total_amount,
        cb_icms,
        icms_percentual,
        icms_amount,
        cb_icms_st,
        st_percentual,
        icms_st_amount,
        cb_ipi,
        ipi_percentual,
        ipi_amount,
        cb_pis,
        pis_percentual,
        pis_amount,
        cb_cofins,
        cofins_percentual,
        cofins_amount,
        difal_percentual,
        difal,
        commission_percentual_ra04,
        commission_amount,
        msrp_pr10,
        discont_percentual_ra06,
        sharing_icms_percentual_ra05,
        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,
        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,
        payment_condition,
        transportation_code,
        transportation_cnpj,
        transportation_name,
        transportation_state,
        iva,
        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,
        chave_de_acesso,
        model,
        model_material_code,
        `key`,
        `month`,
        `year`,
        canceled_bp,
        bp_status,
        check_model,
        dealer_store,
        dealer_group,
        port,
        sales_type,
        check_return_db,
        licensed,
        dt_carga,
        source_file,
        usuario

    )

    SELECT

        chassis_serial_number,
        chassi_validation,
        sap_document,
        company_code,
        plant_code,
        sales_order_number,
        sales_order_type,

        item_categoy,

        delivery_note_number_picking,
        billing_number_vf01,
        invoice_number,
        issuance_date,
        status_doc,
        estornado,
        so_item,
        material,
        ncm,
        origin,
        utiliz_material,
        description,
        chassis_serial_number_1,
        cfop,
        qty,
        total_amount,
        cb_icms,
        icms_percentual,
        icms_amount,
        cb_icms_st,
        st_percentual,
        icms_st_amount,
        cb_ipi,
        ipi_percentual,
        ipi_amount,
        cb_pis,
        pis_percentual,
        pis_amount,
        cb_cofins,
        cofins_percentual,
        cofins_amount,
        difal_percentual,
        difal,
        commission_percentual_ra04,
        commission_amount,
        msrp_pr10,
        discont_percentual_ra06,
        sharing_icms_percentual_ra05,
        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,
        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,
        payment_condition,
        transportation_code,
        transportation_cnpj,
        transportation_name,
        transportation_state,
        iva,
        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,
        chave_de_acesso,
        model,
        model_material_code,
        `key`,
        `month`,
        `year`,
        canceled_bp,
        bp_status,
        check_model,
        dealer_store,
        dealer_group,
        port,
        sales_type,
        check_return_db,
        licensed,
        dt_carga,
        source_file,
        usuario

    FROM bp_datalake.bronze_invoiced_database_2025;


    SET v_rows_2025 = ROW_COUNT();


    /*
    ============================================================
    04. PADRONIZAÇÃO DOS CAMPOS LEGACY
    ============================================================
    */

    UPDATE bp_datalake.silver_invoiced_legacy_2024_2025

    SET

        /*
        Produto
        */

        descricao_do_produto =
            NULLIF(TRIM(description), ''),

        descricao_da_cor =
            NULL,


        /*
        Ano fabricação
        */

        manufacturing_year =
            CASE

                WHEN TRIM(`year`) REGEXP '^[0-9]{4}$'
                    THEN CAST(TRIM(`year`) AS UNSIGNED)

                ELSE NULL

            END,

        model_year =
            NULL,


        /*
        Organização
        */

        byd_cnpj_number =
            NULL,

        division =
            NULLIF(TRIM(sales_order_type), ''),


        /*
        Campos inexistentes no legado
        */

        invoice_series = NULL,

        no_do_motor = NULL,

        codigo_da_cor = NULL,

        potencia_motor = NULL,

        cap_trac_max = NULL,

        cilindradas_cc = NULL,

        distancia_entre_eixo = NULL,

        peso_liquido_ton = NULL,

        peso_bruto_ton = NULL,

        tipo_de_veiculo = NULL,

        especie_do_veiculo = NULL,

        tipo_do_combustivel = NULL,

        tipo_de_pintura = NULL,

        condicao_do_veiculo = NULL,

        cap_ocup_max = NULL,

        vin_condition = NULL,

        code_brand_mode = NULL,


        /*
        Histórico anterior à reconciliação atual
        */

        source_status = 'UNKNOWN',

        proc_time = NULL;


    /*
    ============================================================
    05. TOTAL CARREGADO
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_total_rows
    FROM bp_datalake.silver_invoiced_legacy_2024_2025;


    /*
    ============================================================
    06. RETORNO
    ============================================================
    */

    SELECT

        v_rows_2024 AS rows_2024,

        v_rows_2025 AS rows_2025,

        v_total_rows AS total_silver,

        (
            SELECT COUNT(*)
            FROM bp_datalake.silver_invoiced_legacy_2024_2025
            WHERE manufacturing_year IS NOT NULL
        ) AS manufacturing_year_ok,

        (
            SELECT COUNT(*)
            FROM bp_datalake.silver_invoiced_legacy_2024_2025
            WHERE division IS NOT NULL
        ) AS division_ok,

        (
            SELECT COUNT(*)
            FROM bp_datalake.silver_invoiced_legacy_2024_2025
            WHERE source_status = 'UNKNOWN'
        ) AS source_status_unknown;


END$$


DELIMITER ;