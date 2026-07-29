

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_load_gold_zsdbil17_faturamento$$

CREATE PROCEDURE sp_load_gold_zsdbil17_faturamento()
BEGIN

    /*
    =========================================================
    1. DECLARAÇÃO DAS VARIÁVEIS
    =========================================================
    */

    -- Identificador do registro criado na tabela de log
    DECLARE v_execution_id BIGINT DEFAULT NULL;

    -- Controle de início e fim da execução
    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_finished_at DATETIME DEFAULT NULL;

    -- Contadores da execução
    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_selected_rows BIGINT DEFAULT 0;
    DECLARE v_inserted_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;
    DECLARE v_rejected_rows BIGINT DEFAULT 0;

    -- Informações do erro
    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    =========================================================
    2. TRATAMENTO DE ERRO
    =========================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        /*
        Captura as informações do erro gerado pelo MySQL.
        */

        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        /*
        Desfaz somente as alterações da carga transacional.
        DDLs executados anteriormente podem gerar COMMIT implícito.
        */

        ROLLBACK;

        SET v_finished_at = NOW();

        /*
        O log somente será atualizado se sua execução já tiver sido
        registrada e o ID tiver sido obtido.
        */

        IF v_execution_id IS NOT NULL THEN

            UPDATE etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,

                source_rows = v_source_rows,
                selected_rows = v_selected_rows,
                inserted_rows = v_inserted_rows,
                updated_rows = v_updated_rows,
                rejected_rows = v_rejected_rows,

                error_code = CONCAT(
                    'MYSQL ',
                    v_mysql_errno,
                    ' | SQLSTATE ',
                    v_sqlstate
                ),

                error_message = v_error_message,

                execution_duration_seconds = TIMESTAMPDIFF(
                    SECOND,
                    v_started_at,
                    v_finished_at
                )

            WHERE id_execution = v_execution_id;

        END IF;

        /*
        Devolve o erro para quem chamou a procedure.
        O erro não fica escondido.
        */

        RESIGNAL;

    END;


    /*
    =========================================================
    3. INFRAESTRUTURA — TABELA DE LOG
    =========================================================
    */

    CREATE TABLE IF NOT EXISTS etl_execution_log (
        id_execution BIGINT AUTO_INCREMENT PRIMARY KEY,

        procedure_name VARCHAR(100) NOT NULL,
        source_table VARCHAR(100) NOT NULL,
        target_table VARCHAR(100) NOT NULL,

        execution_status ENUM(
            'RUNNING',
            'SUCCESS',
            'ERROR'
        ) NOT NULL,

        executed_by VARCHAR(100) NOT NULL,

        started_at DATETIME NOT NULL,
        finished_at DATETIME NULL,

        source_rows BIGINT NOT NULL DEFAULT 0,
        selected_rows BIGINT NOT NULL DEFAULT 0,
        inserted_rows BIGINT NOT NULL DEFAULT 0,
        updated_rows BIGINT NOT NULL DEFAULT 0,
        rejected_rows BIGINT NOT NULL DEFAULT 0,

        error_code VARCHAR(100) NULL,
        error_message TEXT NULL,

        execution_duration_seconds BIGINT NULL,

        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

        INDEX idx_etl_log_procedure (
            procedure_name
        ),

        INDEX idx_etl_log_started_at (
            started_at
        ),

        INDEX idx_etl_log_status (
            execution_status
        )
    );


/*
=========================================================
4. INFRAESTRUTURA — TABELA GOLD
=========================================================
*/

CREATE TABLE IF NOT EXISTS gold_zsdbil17_faturamento (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,

    /*
    Rastreabilidade até o registro da Silver que originou este registro da Gold.
    */
    id_silver BIGINT NOT NULL,

    /*
    =====================================================
    DOCUMENTO
    =====================================================
    */

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    material VARCHAR(12),

    /*
    =====================================================
    DESCRIÇÕES
    =====================================================
    */

    description VARCHAR(50),
    descricao_do_produto VARCHAR(255),
    descricao_da_cor VARCHAR(50),

    /*
    =====================================================
    ANO E VALORES
    =====================================================
    */

    manufacturing_year SMALLINT,
    model_year SMALLINT,
    total_amount DECIMAL(15,2),

    /*
    =====================================================
    SOLD TO
    =====================================================
    */

    sold_to_party_code VARCHAR(20),
    sold_to_party_cnpj CHAR(14),
    sold_to_party_name VARCHAR(100),
    sold_to_party_state CHAR(2),

    /*
    =====================================================
    SHIP TO
    =====================================================
    */

    ship_to_party_code VARCHAR(20),
    ship_to_party_cnpj CHAR(14),
    ship_to_party_name VARCHAR(100),
    ship_to_party_state CHAR(2),

    payment_condition VARCHAR(10),

    /*
    =====================================================
    DADOS FISCAIS
    =====================================================
    */

    chave_de_acesso CHAR(44) NOT NULL,
    ncm CHAR(10),
    cfop CHAR(10),
    plant_code VARCHAR(10),
    company_code VARCHAR(12),
    division VARCHAR(5),
    sap_document VARCHAR(10),
    sales_order_number VARCHAR(10),
    invoice_series VARCHAR(8),

    /*
    =====================================================
    DADOS TÉCNICOS DO VEÍCULO
    =====================================================
    */

    no_do_motor VARCHAR(20),
    codigo_da_cor VARCHAR(10),

    potencia_motor SMALLINT,
    cap_trac_max DECIMAL(6,3),
    cilindradas_cc SMALLINT,
    distancia_entre_eixo SMALLINT,
    peso_liquido_ton DECIMAL(6,3),
    peso_bruto_ton DECIMAL(6,3),

    tipo_de_veiculo VARCHAR(20),
    especie_do_veiculo VARCHAR(20),
    tipo_do_combustivel CHAR(2),
    tipo_de_pintura VARCHAR(10),
    condicao_do_veiculo CHAR(1),

    cap_ocup_max TINYINT,

    byd_cnpj_number CHAR(14),
    vin_condition VARCHAR(10),
    code_brand_mode VARCHAR(10),

    /*
    =====================================================
    DADOS COMERCIAIS
    =====================================================
    */

    sales_order_type VARCHAR(6),
    item_category VARCHAR(9),

    /*
    =====================================================
    AUDITORIA
    =====================================================
    */


    /*
    Data de carga herdada do registro de origem na Silver.
    */
    dt_carga_silver DATETIME NULL,

    /*
    Data da última inserção ou atualização realizada na Gold.
    */
    dt_carga_gold DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,


    /*
    Identifica a execução da procedure Gold responsável
    pela última inserção ou atualização deste registro.
    */

    id_execucao BIGINT NOT NULL,

    usuario VARCHAR(100) NOT NULL,
    source_file VARCHAR(255),

    /*
    =====================================================
    RESTRIÇÕES DE UNICIDADE
    =====================================================
    */

    /*
    Na Gold, cada chassi deve possuir somente
    um registro, representando seu faturamento mais recente.
    */

    CONSTRAINT uk_gold_chassi
        UNIQUE (chassis_serial_number),

    /*
    =====================================================
    ÍNDICES DE CONSULTA
    =====================================================
    */

    INDEX idx_gold_invoice_number (
        invoice_number
    ),

    INDEX idx_gold_material (
        material
    ),

    INDEX idx_gold_chave_de_acesso (
        chave_de_acesso
    )


    ) ENGINE = InnoDB;

    /*
    =========================================================
    4.1. ATUALIZAÇÃO DA ESTRUTURA DA GOLD
    =========================================================
    */

    /*
    =========================================================
    5. INÍCIO DA EXECUÇÃO E DO LOG
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
        'sp_load_gold_zsdbil17_faturamento',
        'silver_zsdbil17_faturamento',
        'gold_zsdbil17_faturamento',
        'RUNNING',
        CURRENT_USER(),
        v_started_at
    );

    /*
    Recupera o ID AUTO_INCREMENT do log recém-criado.
    */

    SET v_execution_id = LAST_INSERT_ID();


    /*
    =========================================================
    6. INÍCIO DA CARGA TRANSACIONAL
    =========================================================
    */

    START TRANSACTION;


    /*
    =========================================================
    7. CONTAGEM DA ORIGEM
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM silver_zsdbil17_faturamento;



    /*
    =========================================================
    7.1. CONTAGEM DOS REGISTROS REJEITADOS
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_rejected_rows
    FROM silver_zsdbil17_faturamento AS s
    WHERE
           NULLIF(TRIM(s.chassis_serial_number), '') IS NULL
        OR CHAR_LENGTH(TRIM(s.chassis_serial_number)) <> 17
        OR s.issuance_date IS NULL
        OR COALESCE(TRIM(s.chave_de_acesso), '')
            NOT REGEXP '^[0-9]{44}$';

    /*
    =========================================================
    8. CARGA SILVER → GOLD
    =========================================================
    */


    /*
    =========================================================
    8.1. PREPARAÇÃO DO FATURAMENTO MAIS RECENTE POR CHASSI
    =========================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_gold_latest;
    DROP TEMPORARY TABLE IF EXISTS tmp_gold_ranked;


    /*
    Cria a tabela ranqueada copiando exatamente
    a estrutura válida da Silver.
    */

    CREATE TEMPORARY TABLE tmp_gold_ranked
    LIKE silver_zsdbil17_faturamento;


    /*
    Coluna auxiliar utilizada para identificar
    o registro mais recente de cada chassi.
    */

    ALTER TABLE tmp_gold_ranked
    ADD COLUMN numero_linha BIGINT;


    /*
    Carrega os registros válidos da Silver e atribui
    uma posição para cada faturamento do mesmo chassi.
    */

    INSERT INTO tmp_gold_ranked
    SELECT
        s.*,

        ROW_NUMBER() OVER (
            PARTITION BY TRIM(s.chassis_serial_number)
            ORDER BY
                s.issuance_date DESC,
                s.invoice_number DESC,
                s.id DESC
        ) AS numero_linha

    FROM silver_zsdbil17_faturamento AS s

    WHERE
        NULLIF(TRIM(s.chassis_serial_number), '') IS NOT NULL
        AND CHAR_LENGTH(TRIM(s.chassis_serial_number)) = 17
        AND s.issuance_date IS NOT NULL
        AND TRIM(s.chave_de_acesso) REGEXP '^[0-9]{44}$';


    /*
    Cria a tabela que armazenará somente
    o faturamento mais recente de cada chassi.
    */

    CREATE TEMPORARY TABLE tmp_gold_latest
    LIKE silver_zsdbil17_faturamento;


    /*
    Colunas auxiliares utilizadas pela carga Gold.
    */

    ALTER TABLE tmp_gold_latest
    ADD COLUMN numero_linha BIGINT,
    ADD COLUMN registro_alterado TINYINT NOT NULL DEFAULT 0;


    /*
    Seleciona somente o registro mais recente de cada chassi
    e identifica se ele precisa ser inserido ou atualizado.
    */

    INSERT INTO tmp_gold_latest
    SELECT
        resultado.*,

        CASE
            WHEN g.id IS NULL THEN 1
            WHEN g.id_silver <> resultado.id THEN 1
            WHEN NOT (
                g.dt_carga_silver <=> resultado.dt_carga
            ) THEN 1
            ELSE 0
        END AS registro_alterado

    FROM tmp_gold_ranked AS resultado

    LEFT JOIN gold_zsdbil17_faturamento AS g
        ON g.chassis_serial_number =
           TRIM(resultado.chassis_serial_number)

    WHERE resultado.numero_linha = 1;


    /*
    =========================================================
    8.2. CONTAGEM DOS REGISTROS SELECIONADOS
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows
    FROM tmp_gold_latest;


    /*
    =========================================================
    8.3. CONTAGEM DOS REGISTROS NOVOS
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_inserted_rows
    FROM tmp_gold_latest AS t

    LEFT JOIN gold_zsdbil17_faturamento AS g
           ON g.chassis_serial_number = TRIM(t.chassis_serial_number)

    WHERE g.chassis_serial_number IS NULL;


    /*
    =========================================================
    8.4. CONTAGEM DOS REGISTROS REALMENTE ATUALIZADOS
    =========================================================
    */

    SELECT COUNT(*)
    INTO v_updated_rows
    FROM tmp_gold_latest AS t

    INNER JOIN gold_zsdbil17_faturamento AS g
            ON g.chassis_serial_number = TRIM(t.chassis_serial_number)

    WHERE t.registro_alterado = 1;


    /*
    =========================================================
    8.5. CARGA INCREMENTAL NA GOLD
    =========================================================
    */
    INSERT INTO gold_zsdbil17_faturamento (
        id_silver,
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
        byd_cnpj_number,
        vin_condition,
        code_brand_mode,
        sales_order_type,
        item_category,
        dt_carga_silver,
        dt_carga_gold,
        id_execucao,
        usuario,
        source_file
    )
     SELECT
        t.id AS id_silver,

        TRIM(t.chassis_serial_number),
        TRIM(t.invoice_number),
        t.issuance_date,
        NULLIF(TRIM(t.material), ''),

        NULLIF(TRIM(t.description), ''),
        NULLIF(TRIM(t.descricao_do_produto), ''),
        NULLIF(TRIM(t.descricao_da_cor), ''),


        CASE
            WHEN TRIM(t.manufacturing_year) REGEXP '^[0-9]{4}$'
            THEN CAST(TRIM(t.manufacturing_year) AS UNSIGNED)
            ELSE NULL
        END,

        CASE
            WHEN TRIM(t.model_year) REGEXP '^[0-9]{4}$'
            THEN CAST(TRIM(t.model_year) AS UNSIGNED)
            ELSE NULL
        END,


        t.total_amount,

        NULLIF(TRIM(t.sold_to_party_code), ''),
        NULLIF(TRIM(t.sold_to_party_cnpj), ''),
        NULLIF(TRIM(t.sold_to_party_name), ''),
        NULLIF(TRIM(t.sold_to_party_state), ''),

        NULLIF(TRIM(t.ship_to_party_code), ''),
        NULLIF(TRIM(t.ship_to_party_cnpj), ''),
        NULLIF(TRIM(t.ship_to_party_name), ''),
        NULLIF(TRIM(t.ship_to_party_state), ''),

        NULLIF(TRIM(t.payment_condition), ''),

        TRIM(t.chave_de_acesso),

        NULLIF(REPLACE(TRIM(t.ncm), '.', ''), ''),
        NULLIF(TRIM(t.cfop), ''),
        NULLIF(TRIM(t.plant_code), ''),
        NULLIF(TRIM(t.company_code), ''),
        NULLIF(TRIM(t.division), ''),
        NULLIF(TRIM(t.sap_document), ''),
        NULLIF(TRIM(t.sales_order_number), ''),
        NULLIF(TRIM(t.invoice_series), ''),

        NULLIF(TRIM(t.no_do_motor), ''),
        NULLIF(TRIM(t.codigo_da_cor), ''),

        t.potencia_motor,
        t.cap_trac_max,
        t.cilindradas_cc,
        t.distancia_entre_eixo,
        t.peso_liquido_ton,
        t.peso_bruto_ton,

        NULLIF(TRIM(t.tipo_de_veiculo), ''),
        NULLIF(TRIM(t.especie_do_veiculo), ''),
        NULLIF(TRIM(t.tipo_do_combustivel), ''),
        NULLIF(TRIM(t.tipo_de_pintura), ''),
        NULLIF(TRIM(t.condicao_do_veiculo), ''),

        t.cap_ocup_max,

        NULLIF(TRIM(t.byd_cnpj_number), ''),
        NULLIF(TRIM(t.vin_condition), ''),
        NULLIF(TRIM(t.code_brand_mode), ''),

        NULLIF(TRIM(t.sales_order_type), ''),
        NULLIF(TRIM(t.item_category), ''),

        t.dt_carga,
        NOW(),
        v_execution_id,
        CURRENT_USER(),
        NULLIF(TRIM(t.source_file), '')

    FROM tmp_gold_latest t
    WHERE t.registro_alterado = 1
    ON DUPLICATE KEY UPDATE
    id_silver = t.id,

    chassis_serial_number = TRIM(t.chassis_serial_number),
    invoice_number = TRIM(t.invoice_number),
    issuance_date = t.issuance_date,

    material = NULLIF(TRIM(t.material), ''),
    description = NULLIF(TRIM(t.description), ''),
    descricao_do_produto = NULLIF(TRIM(t.descricao_do_produto), ''),
    descricao_da_cor = NULLIF(TRIM(t.descricao_da_cor), ''),

    manufacturing_year =
        CASE
            WHEN TRIM(t.manufacturing_year) REGEXP '^[0-9]{4}$'
            THEN CAST(TRIM(t.manufacturing_year) AS UNSIGNED)
            ELSE NULL
        END,

    model_year =
        CASE
            WHEN TRIM(t.model_year) REGEXP '^[0-9]{4}$'
            THEN CAST(TRIM(t.model_year) AS UNSIGNED)
            ELSE NULL
        END,


    total_amount = t.total_amount,

    sold_to_party_code = NULLIF(TRIM(t.sold_to_party_code), ''),
    sold_to_party_cnpj = NULLIF(TRIM(t.sold_to_party_cnpj), ''),
    sold_to_party_name = NULLIF(TRIM(t.sold_to_party_name), ''),
    sold_to_party_state = NULLIF(TRIM(t.sold_to_party_state), ''),

    ship_to_party_code = NULLIF(TRIM(t.ship_to_party_code), ''),
    ship_to_party_cnpj = NULLIF(TRIM(t.ship_to_party_cnpj), ''),
    ship_to_party_name = NULLIF(TRIM(t.ship_to_party_name), ''),
    ship_to_party_state = NULLIF(TRIM(t.ship_to_party_state), ''),

    payment_condition = NULLIF(TRIM(t.payment_condition), ''),

    chave_de_acesso = TRIM(t.chave_de_acesso),

    ncm = NULLIF(REPLACE(TRIM(t.ncm), '.', ''), ''),
    cfop = NULLIF(TRIM(t.cfop), ''),
    plant_code = NULLIF(TRIM(t.plant_code), ''),
    company_code = NULLIF(TRIM(t.company_code), ''),
    division = NULLIF(TRIM(t.division), ''),
    sap_document = NULLIF(TRIM(t.sap_document), ''),
    sales_order_number = NULLIF(TRIM(t.sales_order_number), ''),
    invoice_series = NULLIF(TRIM(t.invoice_series), ''),

    no_do_motor = NULLIF(TRIM(t.no_do_motor), ''),
    codigo_da_cor = NULLIF(TRIM(t.codigo_da_cor), ''),

    potencia_motor = t.potencia_motor,
    cap_trac_max = t.cap_trac_max,
    cilindradas_cc = t.cilindradas_cc,
    distancia_entre_eixo = t.distancia_entre_eixo,
    peso_liquido_ton = t.peso_liquido_ton,
    peso_bruto_ton = t.peso_bruto_ton,

    tipo_de_veiculo = NULLIF(TRIM(t.tipo_de_veiculo), ''),
    especie_do_veiculo = NULLIF(TRIM(t.especie_do_veiculo), ''),
    tipo_do_combustivel = NULLIF(TRIM(t.tipo_do_combustivel), ''),
    tipo_de_pintura = NULLIF(TRIM(t.tipo_de_pintura), ''),
    condicao_do_veiculo = NULLIF(TRIM(t.condicao_do_veiculo), ''),

    cap_ocup_max = t.cap_ocup_max,

    byd_cnpj_number = NULLIF(TRIM(t.byd_cnpj_number), ''),
    vin_condition = NULLIF(TRIM(t.vin_condition), ''),
    code_brand_mode = NULLIF(TRIM(t.code_brand_mode), ''),

    sales_order_type = NULLIF(TRIM(t.sales_order_type), ''),
    item_category = NULLIF(TRIM(t.item_category), ''),

    dt_carga_silver = t.dt_carga,
    dt_carga_gold = NOW(),
    id_execucao = v_execution_id,
    usuario = CURRENT_USER(),
    source_file = NULLIF(TRIM(t.source_file), '');
    /*
    =========================================================
    8.6. LIMPEZA DA ÁREA TEMPORÁRIA
    =========================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_gold_latest;
    DROP TEMPORARY TABLE IF EXISTS tmp_gold_ranked;

    /*
    =========================================================
    8.7. CONFIRMAÇÃO DA TRANSAÇÃO
    =========================================================
    */

    COMMIT;

    /*
    =========================================================
    9. FINALIZAÇÃO DA EXECUÇÃO
    =========================================================
    */

    SET v_finished_at = NOW();

    UPDATE etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,

        source_rows = v_source_rows,
        selected_rows = v_selected_rows,
        inserted_rows = v_inserted_rows,
        updated_rows = v_updated_rows,
        rejected_rows = v_rejected_rows,

        error_code = NULL,
        error_message = NULL,

        execution_duration_seconds = TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        )

    WHERE id_execution = v_execution_id;


    /*
    =========================================================
    10. RETORNO DA EXECUÇÃO
    =========================================================
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
        v_selected_rows AS selected_rows,
        v_inserted_rows AS inserted_rows,
        v_updated_rows AS updated_rows,
        v_rejected_rows AS rejected_rows;

END$$

DELIMITER ;