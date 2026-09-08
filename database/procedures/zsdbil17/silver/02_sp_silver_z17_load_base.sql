DELIMITER $$

DROP PROCEDURE IF EXISTS sp_silver_z17_load_base$$

CREATE PROCEDURE sp_silver_z17_load_base()
BEGIN

    /*
    =========================================================
    01. CONTROLE DA EXECUÇÃO
    =========================================================
    */

    DECLARE v_execution_id BIGINT DEFAULT NULL;
    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_finished_at DATETIME DEFAULT NULL;
    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_loaded_rows BIGINT DEFAULT 0;

    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    =========================================================
    02. TRATAMENTO DE ERRO
    =========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;
        SET v_finished_at = NOW();

        IF v_execution_id IS NOT NULL THEN
            UPDATE etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,
                source_rows = v_source_rows,
                selected_rows = v_source_rows,
                inserted_rows = v_loaded_rows,
                updated_rows = 0,
                rejected_rows = 0,
                error_code = CONCAT(
                    'MYSQL ', v_mysql_errno,
                    ' | SQLSTATE ', v_sqlstate
                ),
                error_message = v_error_message,
                execution_duration_seconds = TIMESTAMPDIFF(
                    SECOND, v_started_at, v_finished_at
                )
            WHERE id_execution = v_execution_id;
        END IF;

        RESIGNAL;
    END;


    /*
    =========================================================
    03. AUDITORIA
    =========================================================
    */

    SET v_started_at = NOW();

    INSERT INTO etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at
    )
    VALUES (
        'sp_silver_z17_load_base',
        'bronze_zsdbil17_faturamento',
        'silver_zsdbil17_outbound_movements',
        'RUNNING',
        CURRENT_USER(),
        v_started_at
    );

    SET v_execution_id = LAST_INSERT_ID();

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bronze_zsdbil17_faturamento;


    /*
    =========================================================
    04. FULL REFRESH BRONZE -> SILVER
    =========================================================

    Responsabilidade desta procedure:
    - carregar todas as linhas da Bronze;
    - não filtrar CFOP, NCM, chave ou status;
    - realizar somente conversões técnicas seguras;
    - valor incompatível com o tipo da Silver vira NULL.

    DELETE é usado no lugar de TRUNCATE para permitir ROLLBACK.
    =========================================================
    */

    START TRANSACTION;

    DELETE FROM silver_zsdbil17_outbound_movements;

    INSERT INTO silver_zsdbil17_outbound_movements (
        id_bronze,
        reconciliation_hash,
        sap_document,
        company_code,
        plant_code,
        sales_order_number,
        sales_order_type,
        item_category,
        so_item,
        created_by_so,
        distribution_channel,
        division,
        division_description,
        customer_reference,
        delivery_note_number_picking,
        billing_number_vf01,
        goods_issue_document,
        invoice_number,
        invoice_series,
        issuance_date,
        status_doc,
        estornado,
        chave_de_acesso,
        nf_reference,
        material,
        ncm,
        origin,
        utiliz_material,
        description,
        chassis_serial_number,
        cfop,
        grpmercads,
        tipo_de_operacao,
        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,
        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,
        transportation_code,
        transportation_cnpj,
        transportation_name,
        transportation_state,
        payment_condition,
        payment_condition_description,
        payment_method,
        payment_method_description,
        qty,
        total_amount,
        total_invoice_net_price,
        item_product_amount,
        item_total_net_price,
        msrp_pr00,
        istf_price_fixed,
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
        iva,
        dir_fiscal_icms,
        dir_fiscal_ipi,
        dir_fiscal_iss,
        dir_fiscal_cofins,
        dir_fiscal_pis,
        vlr_fcp_subst_icms,
        bc_fcp,
        fcp_percentual,
        fcp_amount,
        bc_difal,
        difal_percentual,
        difal,
        mva_percentual_ists,
        bc_fcp_subst_icms,
        aliq_fcp_subst_icms,
        commission_percentual_zcom,
        commission_amount,
        discont_percentual_ra01,
        sharing_icms_percentual_zbx9,
        discount_amount_ra01,
        discount_of_pcd_zdvp,
        discount_value_amount_rb00,
        pcd_sales_limit_zlvp,
        dev_venda_sap_doc,
        dev_venda_sales_order,
        dev_venda_so_item,
        dev_venda_material_code,
        dev_venda_description,
        dev_venda_chassis,
        dev_venda_dn_picking,
        dev_venda_billing_number_vf01,
        dev_venda_invoice_number,
        dev_venda_issuance_date,
        dev_venda_status_doc,
        dev_venda_chave_de_acesso,
        n_di,
        data_da_di,
        descricao_do_produto,
        chassi_do_veiculo,
        no_de_serie,
        no_do_motor,
        codigo_da_cor,
        descricao_da_cor,
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
        serie_number,
        byd_icms_st_taxpayer,
        byd_cnpj_number,
        manufacturing_year,
        model_year,
        vin_condition,
        code_brand_mode,
        manufacture_year,
        model_year_1,
        cbs3_base,
        cbs3_rate,
        cbs3_val,
        ib3s_base,
        ib3s_rate,
        ib3s_val,
        ibs_cbs_tax_sitn,
        ibs_cbs_tax_sitn_code,
        ibs_cbs_tax_classification_code,
        proc_time,
        delivery_allocation_address,
        storage_location,
        movement_type,
        assignment_number,
        journal_entry_document,
        um_basic,
        profit_center,
        produced_in_house,
        valuation_class,
        price_control,
        acct_assmt_grp_mat,
        mat_item_category_group,
        material_group_2,
        um_sales,
        dt_carga,
        id_execucao,
        usuario,
        source_file,
        source_status,
        first_seen_at,
        last_seen_at,
        missing_since
    )
    SELECT
        b.id AS id_bronze,
        b.reconciliation_hash AS reconciliation_hash,
        NULLIF(TRIM(b.sap_document), '') AS sap_document,
        NULLIF(TRIM(b.company_code), '') AS company_code,
        NULLIF(TRIM(b.plant_code), '') AS plant_code,
        NULLIF(TRIM(b.sales_order_number), '') AS sales_order_number,
        NULLIF(TRIM(b.sales_order_type), '') AS sales_order_type,
        NULLIF(TRIM(b.item_categoy), '') AS item_category,
        NULLIF(TRIM(b.so_item), '') AS so_item,
        NULLIF(TRIM(b.created_by_so), '') AS created_by_so,
        NULLIF(TRIM(b.distribution_channel), '') AS distribution_channel,
        NULLIF(TRIM(b.division), '') AS division,
        NULLIF(TRIM(b.division_description), '') AS division_description,
        NULLIF(TRIM(b.customer_reference), '') AS customer_reference,
        NULLIF(TRIM(b.delivery_note_number_picking), '') AS delivery_note_number_picking,
        NULLIF(TRIM(b.billing_number_vf01), '') AS billing_number_vf01,
        NULLIF(TRIM(b.goods_issue_document), '') AS goods_issue_document,
        NULLIF(TRIM(b.invoice_number), '') AS invoice_number,
        NULLIF(TRIM(b.invoice_series), '') AS invoice_series,
        b.issuance_date AS issuance_date,
        NULLIF(TRIM(b.status_doc), '') AS status_doc,
        NULLIF(TRIM(b.estornado), '') AS estornado,
        NULLIF(TRIM(b.chave_de_acesso), '') AS chave_de_acesso,
        NULLIF(TRIM(b.nf_reference), '') AS nf_reference,
        NULLIF(TRIM(b.material), '') AS material,
        NULLIF(TRIM(b.ncm), '') AS ncm,
        NULLIF(TRIM(b.origin), '') AS origin,
        NULLIF(TRIM(b.utiliz_material), '') AS utiliz_material,
        NULLIF(TRIM(b.description), '') AS description,
        NULLIF(TRIM(b.chassis_serial_number), '') AS chassis_serial_number,
        NULLIF(TRIM(b.cfop), '') AS cfop,
        NULLIF(TRIM(b.grpmercads), '') AS grpmercads,
        NULLIF(TRIM(b.tipo_de_operacao), '') AS tipo_de_operacao,
        NULLIF(TRIM(b.sold_to_party_code), '') AS sold_to_party_code,
        NULLIF(TRIM(b.sold_to_party_cnpj), '') AS sold_to_party_cnpj,
        NULLIF(TRIM(b.sold_to_party_name), '') AS sold_to_party_name,
        NULLIF(TRIM(b.sold_to_party_state), '') AS sold_to_party_state,
        NULLIF(TRIM(b.ship_to_party_code), '') AS ship_to_party_code,
        NULLIF(TRIM(b.ship_to_party_cnpj), '') AS ship_to_party_cnpj,
        NULLIF(TRIM(b.ship_to_party_name), '') AS ship_to_party_name,
        NULLIF(TRIM(b.ship_to_party_state), '') AS ship_to_party_state,
        NULLIF(TRIM(b.transportation_code), '') AS transportation_code,
        NULLIF(TRIM(b.transportation_cnpj), '') AS transportation_cnpj,
        NULLIF(TRIM(b.transportation_name), '') AS transportation_name,
        NULLIF(TRIM(b.transportation_state), '') AS transportation_state,
        NULLIF(TRIM(b.payment_condition), '') AS payment_condition,
        NULLIF(TRIM(b.payment_condition_description), '') AS payment_condition_description,
        NULLIF(TRIM(b.payment_method), '') AS payment_method,
        NULLIF(TRIM(b.payment_method_descripition), '') AS payment_method_description,
        CASE WHEN TRIM(REPLACE(b.qty, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,15}([.][0-9]{1,3}0*)?$' THEN CAST(TRIM(REPLACE(b.qty, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,3)) ELSE NULL END AS qty,
        CASE WHEN TRIM(REPLACE(b.total_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.total_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS total_amount,
        CASE WHEN TRIM(REPLACE(b.total_invoice_net_price, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.total_invoice_net_price, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS total_invoice_net_price,
        CASE WHEN TRIM(REPLACE(b.item_product_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.item_product_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS item_product_amount,
        CASE WHEN TRIM(REPLACE(b.item_total_net_price, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.item_total_net_price, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS item_total_net_price,
        CASE WHEN TRIM(REPLACE(b.msrp_pr00, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.msrp_pr00, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS msrp_pr00,
        CASE WHEN TRIM(REPLACE(b.istf_price_fixed, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.istf_price_fixed, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS istf_price_fixed,
        CASE WHEN TRIM(REPLACE(b.cb_icms, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cb_icms, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cb_icms,
        CASE WHEN TRIM(REPLACE(b.icms_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.icms_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS icms_percentual,
        CASE WHEN TRIM(REPLACE(b.icms_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.icms_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS icms_amount,
        CASE WHEN TRIM(REPLACE(b.cb_icms_st, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cb_icms_st, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cb_icms_st,
        CASE WHEN TRIM(REPLACE(b.st_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.st_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS st_percentual,
        CASE WHEN TRIM(REPLACE(b.icms_st_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.icms_st_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS icms_st_amount,
        CASE WHEN TRIM(REPLACE(b.cb_ipi, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cb_ipi, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cb_ipi,
        CASE WHEN TRIM(REPLACE(b.ipi_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.ipi_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS ipi_percentual,
        CASE WHEN TRIM(REPLACE(b.ipi_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.ipi_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS ipi_amount,
        CASE WHEN TRIM(REPLACE(b.cb_pis, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cb_pis, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cb_pis,
        CASE WHEN TRIM(REPLACE(b.pis_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.pis_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS pis_percentual,
        CASE WHEN TRIM(REPLACE(b.pis_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.pis_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS pis_amount,
        CASE WHEN TRIM(REPLACE(b.cb_cofins, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cb_cofins, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cb_cofins,
        CASE WHEN TRIM(REPLACE(b.cofins_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.cofins_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS cofins_percentual,
        CASE WHEN TRIM(REPLACE(b.cofins_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cofins_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cofins_amount,
        NULLIF(TRIM(b.iva), '') AS iva,
        NULLIF(TRIM(b.dir_fiscal_icms), '') AS dir_fiscal_icms,
        NULLIF(TRIM(b.dir_fiscal_ipi), '') AS dir_fiscal_ipi,
        NULLIF(TRIM(b.dir_fiscal_iss), '') AS dir_fiscal_iss,
        NULLIF(TRIM(b.dir_fiscal_cofins), '') AS dir_fiscal_cofins,
        NULLIF(TRIM(b.dir_fiscal_pis), '') AS dir_fiscal_pis,
        CASE WHEN TRIM(REPLACE(b.vlr_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.vlr_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS vlr_fcp_subst_icms,
        CASE WHEN TRIM(REPLACE(b.bc_fcp, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.bc_fcp, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS bc_fcp,
        CASE WHEN TRIM(REPLACE(b.fcp_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.fcp_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS fcp_percentual,
        CASE WHEN TRIM(REPLACE(b.fcp_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.fcp_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS fcp_amount,
        CASE WHEN TRIM(REPLACE(b.bc_difal, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.bc_difal, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS bc_difal,
        CASE WHEN TRIM(REPLACE(b.difal_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.difal_percentual, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS difal_percentual,
        CASE WHEN TRIM(REPLACE(b.difal, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.difal, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS difal,
        CASE WHEN TRIM(REPLACE(b.mva_percentual_ists, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.mva_percentual_ists, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS mva_percentual_ists,
        CASE WHEN TRIM(REPLACE(b.bc_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.bc_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS bc_fcp_subst_icms,
        CASE WHEN TRIM(REPLACE(b.aliq_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.aliq_fcp_subst_icms, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS aliq_fcp_subst_icms,
        CASE WHEN TRIM(REPLACE(b.commission_percentual_zcom, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.commission_percentual_zcom, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS commission_percentual_zcom,
        CASE WHEN TRIM(REPLACE(b.commission_amount, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.commission_amount, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS commission_amount,
        CASE WHEN TRIM(REPLACE(b.discont_percentual_ra01, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.discont_percentual_ra01, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS discont_percentual_ra01,
        CASE WHEN TRIM(REPLACE(b.sharing_icms_percentual_zbx9, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.sharing_icms_percentual_zbx9, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS sharing_icms_percentual_zbx9,
        CASE WHEN TRIM(REPLACE(b.discount_amount_ra01, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.discount_amount_ra01, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS discount_amount_ra01,
        CASE WHEN TRIM(REPLACE(b.discount_of_pcd_zdvp, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.discount_of_pcd_zdvp, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS discount_of_pcd_zdvp,
        CASE WHEN TRIM(REPLACE(b.discount_value_amount_rb00, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.discount_value_amount_rb00, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS discount_value_amount_rb00,
        CASE WHEN TRIM(REPLACE(b.pcd_sales_limit_zlvp, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.pcd_sales_limit_zlvp, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS pcd_sales_limit_zlvp,
        NULLIF(TRIM(b.dev_venda_sap_doc), '') AS dev_venda_sap_doc,
        NULLIF(TRIM(b.dev_venda_sales_order), '') AS dev_venda_sales_order,
        NULLIF(TRIM(b.dev_venda_so_item), '') AS dev_venda_so_item,
        NULLIF(TRIM(b.dev_venda_material_code), '') AS dev_venda_material_code,
        NULLIF(TRIM(b.dev_venda_description), '') AS dev_venda_description,
        NULLIF(TRIM(b.dev_venda_chassis), '') AS dev_venda_chassis,
        NULLIF(TRIM(b.dev_venda_dn_picking), '') AS dev_venda_dn_picking,
        NULLIF(TRIM(b.dev_venda_billing_number_vf01), '') AS dev_venda_billing_number_vf01,
        NULLIF(TRIM(b.dev_venda_invoice_number), '') AS dev_venda_invoice_number,
        CASE WHEN (TRIM(b.dev_venda_issuance_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND CAST(SUBSTRING(TRIM(b.dev_venda_issuance_date), 6, 2) AS UNSIGNED) BETWEEN 1 AND 12 AND CAST(SUBSTRING(TRIM(b.dev_venda_issuance_date), 9, 2) AS UNSIGNED) BETWEEN 1 AND DAY(LAST_DAY(CONCAT(SUBSTRING(TRIM(b.dev_venda_issuance_date), 1, 4), '-', SUBSTRING(TRIM(b.dev_venda_issuance_date), 6, 2), '-01')))) THEN STR_TO_DATE(TRIM(b.dev_venda_issuance_date), '%Y-%m-%d') WHEN (TRIM(b.dev_venda_issuance_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' AND CAST(SUBSTRING(TRIM(b.dev_venda_issuance_date), 4, 2) AS UNSIGNED) BETWEEN 1 AND 12 AND CAST(SUBSTRING(TRIM(b.dev_venda_issuance_date), 1, 2) AS UNSIGNED) BETWEEN 1 AND DAY(LAST_DAY(CONCAT(SUBSTRING(TRIM(b.dev_venda_issuance_date), 7, 4), '-', SUBSTRING(TRIM(b.dev_venda_issuance_date), 4, 2), '-01')))) THEN STR_TO_DATE(TRIM(b.dev_venda_issuance_date), '%d/%m/%Y') ELSE NULL END AS dev_venda_issuance_date,
        NULLIF(TRIM(b.dev_venda_status_doc), '') AS dev_venda_status_doc,
        NULLIF(TRIM(b.dev_venda_chave_de_acesso), '') AS dev_venda_chave_de_acesso,
        NULLIF(TRIM(b.n_di), '') AS n_di,
        CASE WHEN (TRIM(b.data_da_di) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND CAST(SUBSTRING(TRIM(b.data_da_di), 6, 2) AS UNSIGNED) BETWEEN 1 AND 12 AND CAST(SUBSTRING(TRIM(b.data_da_di), 9, 2) AS UNSIGNED) BETWEEN 1 AND DAY(LAST_DAY(CONCAT(SUBSTRING(TRIM(b.data_da_di), 1, 4), '-', SUBSTRING(TRIM(b.data_da_di), 6, 2), '-01')))) THEN STR_TO_DATE(TRIM(b.data_da_di), '%Y-%m-%d') WHEN (TRIM(b.data_da_di) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' AND CAST(SUBSTRING(TRIM(b.data_da_di), 4, 2) AS UNSIGNED) BETWEEN 1 AND 12 AND CAST(SUBSTRING(TRIM(b.data_da_di), 1, 2) AS UNSIGNED) BETWEEN 1 AND DAY(LAST_DAY(CONCAT(SUBSTRING(TRIM(b.data_da_di), 7, 4), '-', SUBSTRING(TRIM(b.data_da_di), 4, 2), '-01')))) THEN STR_TO_DATE(TRIM(b.data_da_di), '%d/%m/%Y') ELSE NULL END AS data_da_di,
        NULLIF(TRIM(b.descricao_do_produto), '') AS descricao_do_produto,
        NULLIF(TRIM(b.chassi_do_veiculo), '') AS chassi_do_veiculo,
        NULLIF(TRIM(b.no_de_serie), '') AS no_de_serie,
        NULLIF(TRIM(b.no_do_motor), '') AS no_do_motor,
        NULLIF(TRIM(b.codigo_da_cor), '') AS codigo_da_cor,
        NULLIF(TRIM(b.descricao_da_cor), '') AS descricao_da_cor,
        CASE WHEN TRIM(REPLACE(b.potencia_motor, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,8}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.potencia_motor, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,2)) ELSE NULL END AS potencia_motor,
        CASE WHEN TRIM(REPLACE(b.cap_trac_max, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,6}([.][0-9]{1,4}0*)?$' THEN CAST(TRIM(REPLACE(b.cap_trac_max, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,4)) ELSE NULL END AS cap_trac_max,
        CASE WHEN TRIM(REPLACE(b.cilindradas_cc, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,8}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cilindradas_cc, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,2)) ELSE NULL END AS cilindradas_cc,
        CASE WHEN TRIM(REPLACE(b.distancia_entre_eixo, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,8}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.distancia_entre_eixo, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,2)) ELSE NULL END AS distancia_entre_eixo,
        CASE WHEN TRIM(REPLACE(b.peso_liquido_ton, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,6}([.][0-9]{1,4}0*)?$' THEN CAST(TRIM(REPLACE(b.peso_liquido_ton, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,4)) ELSE NULL END AS peso_liquido_ton,
        CASE WHEN TRIM(REPLACE(b.peso_bruto_ton, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,6}([.][0-9]{1,4}0*)?$' THEN CAST(TRIM(REPLACE(b.peso_bruto_ton, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(10,4)) ELSE NULL END AS peso_bruto_ton,
        NULLIF(TRIM(b.tipo_de_veiculo), '') AS tipo_de_veiculo,
        NULLIF(TRIM(b.especie_do_veiculo), '') AS especie_do_veiculo,
        NULLIF(TRIM(b.tipo_do_combustivel), '') AS tipo_do_combustivel,
        NULLIF(TRIM(b.tipo_de_pintura), '') AS tipo_de_pintura,
        NULLIF(TRIM(b.condicao_do_veiculo), '') AS condicao_do_veiculo,
        CASE WHEN TRIM(REPLACE(b.cap_ocup_max, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,5}$' AND CAST(TRIM(REPLACE(b.cap_ocup_max, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(5,0)) BETWEEN -32768 AND 32767 THEN CAST(TRIM(REPLACE(b.cap_ocup_max, CONVERT(0xC2A0 USING utf8mb4), '')) AS SIGNED) ELSE NULL END AS cap_ocup_max,
        NULLIF(TRIM(b.serie_number), '') AS serie_number,
        NULLIF(TRIM(b.byd_icms_st_taxpayer), '') AS byd_icms_st_taxpayer,
        NULLIF(TRIM(b.byd_cnpj_number), '') AS byd_cnpj_number,
        CASE WHEN TRIM(REPLACE(b.manufacturing_year, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,5}$' AND CAST(TRIM(REPLACE(b.manufacturing_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(5,0)) BETWEEN -32768 AND 32767 THEN CAST(TRIM(REPLACE(b.manufacturing_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS SIGNED) ELSE NULL END AS manufacturing_year,
        CASE WHEN TRIM(REPLACE(b.model_year, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,5}$' AND CAST(TRIM(REPLACE(b.model_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(5,0)) BETWEEN -32768 AND 32767 THEN CAST(TRIM(REPLACE(b.model_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS SIGNED) ELSE NULL END AS model_year,
        NULLIF(TRIM(b.vin_condition), '') AS vin_condition,
        NULLIF(TRIM(b.code_brand_mode), '') AS code_brand_mode,
        CASE WHEN TRIM(REPLACE(b.manufacture_year, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,5}$' AND CAST(TRIM(REPLACE(b.manufacture_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(5,0)) BETWEEN -32768 AND 32767 THEN CAST(TRIM(REPLACE(b.manufacture_year, CONVERT(0xC2A0 USING utf8mb4), '')) AS SIGNED) ELSE NULL END AS manufacture_year,
        CASE WHEN TRIM(REPLACE(b.model_year_1, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,5}$' AND CAST(TRIM(REPLACE(b.model_year_1, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(5,0)) BETWEEN -32768 AND 32767 THEN CAST(TRIM(REPLACE(b.model_year_1, CONVERT(0xC2A0 USING utf8mb4), '')) AS SIGNED) ELSE NULL END AS model_year_1,
        CASE WHEN TRIM(REPLACE(b.cbs3_base, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cbs3_base, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cbs3_base,
        CASE WHEN TRIM(REPLACE(b.cbs3_rate, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.cbs3_rate, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS cbs3_rate,
        CASE WHEN TRIM(REPLACE(b.cbs3_val, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.cbs3_val, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS cbs3_val,
        CASE WHEN TRIM(REPLACE(b.ib3s_base, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.ib3s_base, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS ib3s_base,
        CASE WHEN TRIM(REPLACE(b.ib3s_rate, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,9}([.][0-9]{1,9}0*)?$' THEN CAST(TRIM(REPLACE(b.ib3s_rate, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,9)) ELSE NULL END AS ib3s_rate,
        CASE WHEN TRIM(REPLACE(b.ib3s_val, CONVERT(0xC2A0 USING utf8mb4), '')) REGEXP '^-?[0-9]{1,16}([.][0-9]{1,2}0*)?$' THEN CAST(TRIM(REPLACE(b.ib3s_val, CONVERT(0xC2A0 USING utf8mb4), '')) AS DECIMAL(18,2)) ELSE NULL END AS ib3s_val,
        NULLIF(TRIM(b.ibs_cbs_tax_sitn), '') AS ibs_cbs_tax_sitn,
        NULLIF(TRIM(b.ibs_cbs_tax_sitn_code), '') AS ibs_cbs_tax_sitn_code,
        NULLIF(TRIM(b.ibs_cbs_tax_classification_code), '') AS ibs_cbs_tax_classification_code,
        CASE WHEN TRIM(b.proc_time) REGEXP '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN CAST(TRIM(b.proc_time) AS TIME) ELSE NULL END AS proc_time,
        NULLIF(TRIM(b.delivery_allocation_address), '') AS delivery_allocation_address,
        NULLIF(TRIM(b.storage_location), '') AS storage_location,
        NULLIF(TRIM(b.movement_type), '') AS movement_type,
        NULLIF(TRIM(b.assignment_number), '') AS assignment_number,
        NULLIF(TRIM(b.journal_entry_document), '') AS journal_entry_document,
        NULLIF(TRIM(b.um_basic), '') AS um_basic,
        NULLIF(TRIM(b.profit_center), '') AS profit_center,
        NULLIF(TRIM(b.produced_in_house), '') AS produced_in_house,
        NULLIF(TRIM(b.valuation_class), '') AS valuation_class,
        NULLIF(TRIM(b.price_control), '') AS price_control,
        NULLIF(TRIM(b.acct_assmt_grp_mat), '') AS acct_assmt_grp_mat,
        NULLIF(TRIM(b.mat_item_category_group), '') AS mat_item_category_group,
        NULLIF(TRIM(b.material_group_2), '') AS material_group_2,
        NULLIF(TRIM(b.um_sales), '') AS um_sales,
        CASE WHEN TRIM(b.dt_carga) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]+$' THEN STR_TO_DATE(TRIM(b.dt_carga), '%Y-%m-%d %H:%i:%s.%f') WHEN TRIM(b.dt_carga) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN STR_TO_DATE(TRIM(b.dt_carga), '%Y-%m-%d %H:%i:%s') ELSE NULL END AS dt_carga,
        NULLIF(TRIM(b.id_execucao), '') AS id_execucao,
        NULLIF(TRIM(b.usuario), '') AS usuario,
        NULLIF(TRIM(b.source_file), '') AS source_file,
        b.source_status AS source_status,
        b.first_seen_at AS first_seen_at,
        b.last_seen_at AS last_seen_at,
        b.missing_since AS missing_since
    FROM bronze_zsdbil17_faturamento AS b;

    SET v_loaded_rows = ROW_COUNT();

    IF v_loaded_rows <> v_source_rows THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Load base inconsistente: total Silver diferente da Bronze';
    END IF;

    COMMIT;


    /*
    =========================================================
    05. FINALIZAÇÃO
    =========================================================
    */

    SET v_finished_at = NOW();

    UPDATE etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,
        source_rows = v_source_rows,
        selected_rows = v_source_rows,
        inserted_rows = v_loaded_rows,
        updated_rows = 0,
        rejected_rows = 0,
        error_code = NULL,
        error_message = NULL,
        execution_duration_seconds = TIMESTAMPDIFF(
            SECOND, v_started_at, v_finished_at
        )
    WHERE id_execution = v_execution_id;

    SELECT
        v_execution_id AS execution_id,
        'SUCCESS' AS execution_status,
        v_source_rows AS source_rows,
        v_loaded_rows AS loaded_rows,
        TIMESTAMPDIFF(
            SECOND, v_started_at, v_finished_at
        ) AS execution_duration_seconds;

END$$

DELIMITER ;
