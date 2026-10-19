
/*
============================================================
ZSDBIL17 - SILVER
07 - VEHICLE TYPE CLASSIFICATION
============================================================

Objetivo:
Classificar os materiais faturados como CAR, BUS_TRUCK
ou UNKNOWN utilizando as tabelas de referência.

Tabela de destino:
    silver_zsdbil17_outbound_movements

Tabelas de referência:
    dim_zsdbil17_material_exclusion
    material_master

Coluna gerenciada:
    vehicle_type_code

Prioridade:
1. Material na dimensão de exclusão -> BUS_TRUCK
2. Material na material_master      -> CAR
3. Sem correspondência              -> UNKNOWN

Regras de publicação:
    CAR       -> Elegível para Invoiced DB
    BUS_TRUCK -> Não elegível para Invoiced DB
    UNKNOWN   -> Elegível para Invoiced DB

Estratégia de performance:
- Cria a coluna somente se necessário.
- Monta um mapa temporário indexado por material.
- Consulta as tabelas de referência uma vez por execução.
- Processa somente NULL, vazio e UNKNOWN.
- Evita atualizações quando o valor não mudou.
- Preserva classificações CAR e BUS_TRUCK existentes.

Atenção:
Alterações em materiais já classificados exigem uma
reclassificação completa, a ser tratada separadamente.

============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_vehicle_type;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_z17_vehicle_type()
BEGIN

    DECLARE v_column_exists INT DEFAULT 0;
    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_pending_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;

    DECLARE v_car_rows BIGINT DEFAULT 0;
    DECLARE v_bus_truck_rows BIGINT DEFAULT 0;
    DECLARE v_unknown_rows BIGINT DEFAULT 0;


    /*
    ============================================================
    TRATAMENTO DE ERROS
    ============================================================

    Se ocorrer um erro, remove a tabela temporária
    e propaga a exceção para o processo chamador.

    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_vehicle_material_map;
        RESIGNAL;
    END;


    /*
    ============================================================
    1. VERIFICA SE A COLUNA EXISTE
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_column_exists
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = 'bp_datalake'
      AND TABLE_NAME = 'silver_zsdbil17_outbound_movements'
      AND COLUMN_NAME = 'vehicle_type_code';


    /*
    ============================================================
    2. CRIA A COLUNA SOMENTE SE NECESSÁRIO
    ============================================================

    A coluna será criada imediatamente após material.

    Caso já exista, a estrutura será preservada.

    ============================================================
    */

    IF v_column_exists = 0 THEN

        ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
        ADD COLUMN vehicle_type_code VARCHAR(20) NULL
        COMMENT 'Tipo de veículo: CAR, BUS_TRUCK ou UNKNOWN'
        AFTER material;

    END IF;


    /*
    ============================================================
    3. IDENTIFICA OS REGISTROS PENDENTES
    ============================================================

    Somente registros sem classificação definitiva
    deverão ser reavaliados.

    ============================================================
    */

    SELECT
        COUNT(*),
        COUNT(
            CASE
                WHEN vehicle_type_code IS NULL
                  OR TRIM(vehicle_type_code) = ''
                  OR vehicle_type_code = 'UNKNOWN'
                THEN 1
            END
        )
    INTO
        v_source_rows,
        v_pending_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    4. PROCESSAMENTO INCREMENTAL
    ============================================================

    Caso existam registros pendentes, cria um mapa temporário
    com os materiais já identificados no Data Lake.

    O mapa possui chave primária em material para permitir
    buscas eficientes durante a atualização da Silver.

    ============================================================
    */

    IF v_pending_rows > 0 THEN

        /*
        ========================================================
        4.1. PREPARA A TABELA TEMPORÁRIA
        ========================================================

        A tabela existe somente na sessão atual.

        A collation explícita padroniza as comparações,
        evitando conflitos entre tabelas de origem.

        ========================================================
        */

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_vehicle_material_map;

        CREATE TEMPORARY TABLE tmp_z17_vehicle_material_map (
            material VARCHAR(255)
                CHARACTER SET utf8mb4
                COLLATE utf8mb4_0900_ai_ci NOT NULL,

            vehicle_type_code VARCHAR(20) NOT NULL,

            PRIMARY KEY (material)
        ) ENGINE = InnoDB;


        /*
        ========================================================
        4.2. CARREGA OS MATERIAIS BUS/TRUCK
        ========================================================

        A dimensão de exclusão possui prioridade máxima.

        Somente materiais ativos são considerados.

        INSERT IGNORE evita duplicar o mesmo código
        após a normalização dos espaços.

        ========================================================
        */

        INSERT IGNORE INTO tmp_z17_vehicle_material_map (
            material,
            vehicle_type_code
        )
        SELECT DISTINCT
            CONVERT(TRIM(d.material) USING utf8mb4)
                COLLATE utf8mb4_0900_ai_ci,
            'BUS_TRUCK'
        FROM bp_datalake.dim_zsdbil17_material_exclusion AS d
        WHERE d.active = TRUE
          AND d.material IS NOT NULL
          AND TRIM(d.material) <> '';


        /*
        ========================================================
        4.3. CARREGA OS MATERIAIS DE CARROS
        ========================================================

        Qualquer material existente em material_master.cod_sap
        será considerado CAR.

        A prioridade BUS_TRUCK será preservada pelo
        INSERT IGNORE e pela chave primária.

        ========================================================
        */

        INSERT IGNORE INTO tmp_z17_vehicle_material_map (
            material,
            vehicle_type_code
        )
        SELECT DISTINCT
            CONVERT(TRIM(m.cod_sap) USING utf8mb4)
                COLLATE utf8mb4_0900_ai_ci,
            'CAR'
        FROM bp_datalake.material_master AS m
        WHERE m.cod_sap IS NOT NULL
          AND TRIM(m.cod_sap) <> '';


        /*
        ========================================================
        4.4. CLASSIFICA OS REGISTROS PENDENTES
        ========================================================

        A Silver é comparada com o mapa temporário
        utilizando a chave primária do material.

        Sem correspondência:
            UNKNOWN

        O operador <=> permite comparar valores NULL
        corretamente.

        Registros já classificados como CAR ou BUS_TRUCK
        não participam da atualização.

        ========================================================
        */

        UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

        LEFT JOIN tmp_z17_vehicle_material_map AS m
            ON CONVERT(TRIM(s.material) USING utf8mb4)
                COLLATE utf8mb4_0900_ai_ci = m.material

        SET
            s.vehicle_type_code =
                COALESCE(m.vehicle_type_code, 'UNKNOWN')

        WHERE
            (
                s.vehicle_type_code IS NULL
                OR TRIM(s.vehicle_type_code) = ''
                OR s.vehicle_type_code = 'UNKNOWN'
            )
            AND NOT (
                s.vehicle_type_code <=>
                COALESCE(m.vehicle_type_code, 'UNKNOWN')
            );

        SET v_updated_rows = ROW_COUNT();


        /*
        ========================================================
        4.5. REMOVE A TABELA TEMPORÁRIA
        ========================================================

        O mapa é recriado em cada execução que possua
        registros pendentes.

        ========================================================
        */

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_vehicle_material_map;

    END IF;


    /*
    ============================================================
    5. MÉTRICAS FINAIS
    ============================================================

    Conta todas as classificações existentes na Silver,
    independentemente de terem sido atualizadas nesta
    execução.

    ============================================================
    */

    SELECT
        COUNT(CASE WHEN vehicle_type_code = 'CAR'
                   THEN 1 END),
        COUNT(CASE WHEN vehicle_type_code = 'BUS_TRUCK'
                   THEN 1 END),
        COUNT(CASE WHEN vehicle_type_code = 'UNKNOWN'
                   THEN 1 END)
    INTO
        v_car_rows,
        v_bus_truck_rows,
        v_unknown_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    6. RESULTADO DA EXECUÇÃO
    ============================================================

    source_rows:
        Total de registros da Silver.

    pending_rows:
        Quantidade inicialmente elegível à reclassificação.

    updated_rows:
        Registros efetivamente alterados.

    eligible_gold_rows:
        CAR + UNKNOWN, considerando somente o filtro
        de tipo de veículo.

    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_source_rows AS source_rows,
        v_pending_rows AS pending_rows,
        v_updated_rows AS updated_rows,
        v_car_rows AS car_rows,
        v_bus_truck_rows AS bus_truck_rows,
        v_unknown_rows AS unknown_rows,
        v_car_rows + v_unknown_rows AS eligible_gold_rows;

END$$

DELIMITER ;
