/*
============================================================
DIMENSÃO - CLASSIFICAÇÃO DE MATERIAIS
02 - sp_refresh_dim_material_classification
============================================================

Objetivo:
Manter a dim_material_classification em dia antes da regra de
chassi da Silver da Z17 (ADR-016 do sap_service).

Prioridade quando o mesmo material aparece em mais de uma fonte
(a primeira vence):
    1. MANUAL / SEED_*   decisão do time (nunca é tocada aqui)
    2. EXCLUSION         dim_zsdbil17_material_exclusion -> BUS_TRUCK
    3. MATERIAL_CODE     bronze_vehicle_material_code    -> CAR
    4. SAP_GROUP         material_group_2 = 'B1' na Silver -> PART

Estratégia:
- EXCLUSION e MATERIAL_CODE são pequenas (centenas de linhas):
  são apagadas e recarregadas a cada execução. Assim um material
  removido do Material Code ou desativado na exclusão sai daqui.
- SAP_GROUP é incremental: só olha as linhas da Silver ainda sem
  chassis_rule (as novas desta carga). Na primeira execução todas
  as linhas estão sem chassis_rule, então ela já faz o histórico
  completo. Linhas SAP_GROUP antigas são mantidas.
- Uma fonte de prioridade maior sobrescreve uma SAP_GROUP já
  gravada (ex.: peça que depois foi cadastrada no Material Code).

Cuidados:
- ON DUPLICATE KEY UPDATE avalia as atribuições da esquerda para
  a direita com o valor já atualizado. Por isso "source" é sempre
  a ÚLTIMA atribuição: as anteriores ainda enxergam a origem antiga.
- O grupo G1 (veículo) NÃO vira CAR aqui: carro sem Material Code
  fica sem classificação e cai na fallback
  (FALLBACK_VEHICLE_MATERIAL_NOT_REGISTERED), para alguém cadastrar.

============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_refresh_dim_material_classification;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_refresh_dim_material_classification()
BEGIN

    /*
    ========================================================
    1. REMOVE AS LINHAS RECARREGÁVEIS
    ========================================================
    MANUAL, SEED_* e SAP_GROUP permanecem.
    ========================================================
    */

    DELETE FROM bp_datalake.dim_material_classification
    WHERE source IN ('EXCLUSION', 'MATERIAL_CODE');


    /*
    ========================================================
    2. ÔNIBUS / CAMINHÃO (EXCLUSÃO)
    ========================================================
    Só materiais ativos. Sobrescreve apenas SAP_GROUP.
    ========================================================
    */

    INSERT INTO bp_datalake.dim_material_classification (
        material,
        material_type,
        source,
        description,
        updated_by
    )
    SELECT
        x.source_material,
        'BUS_TRUCK',
        'EXCLUSION',
        x.source_description,
        CURRENT_USER()
    FROM (
        SELECT
            TRIM(e.material) AS source_material,
            MAX(LEFT(e.description, 255)) AS source_description
        FROM bp_datalake.dim_zsdbil17_material_exclusion AS e
        WHERE e.active = TRUE
          AND NULLIF(TRIM(e.material), '') IS NOT NULL
        GROUP BY TRIM(e.material)
    ) AS x
    -- Colunas do derivado com prefixo source_ para não ficarem
    -- ambíguas com as colunas da tabela no ON DUPLICATE KEY UPDATE.
    ON DUPLICATE KEY UPDATE
        material_type = IF(source = 'SAP_GROUP', 'BUS_TRUCK', material_type),
        description   = IF(source = 'SAP_GROUP', x.source_description, description),
        updated_by    = IF(source = 'SAP_GROUP', CURRENT_USER(), updated_by),
        source        = IF(source = 'SAP_GROUP', 'EXCLUSION', source);


    /*
    ========================================================
    3. CARROS (MATERIAL CODE)
    ========================================================
    Mesma leitura do sp_silver_z17_vehicle_type: qualquer cod_sap
    do Material Code é carro. CAST + CONVERT evitam mistura de
    collations. Não sobrescreve MANUAL, SEED nem EXCLUSION.
    ========================================================
    */

    INSERT INTO bp_datalake.dim_material_classification (
        material,
        material_type,
        source,
        description,
        updated_by
    )
    SELECT
        x.source_material,
        'CAR',
        'MATERIAL_CODE',
        x.source_description,
        CURRENT_USER()
    FROM (
        SELECT
            CONVERT(TRIM(CAST(m.cod_sap AS CHAR)) USING utf8mb4)
                COLLATE utf8mb4_0900_ai_ci AS source_material,
            MAX(LEFT(m.descricao_sap, 255)) AS source_description
        FROM bp_datalake.bronze_vehicle_material_code AS m
        WHERE m.cod_sap IS NOT NULL
          AND TRIM(CAST(m.cod_sap AS CHAR)) <> ''
        GROUP BY 1
    ) AS x
    ON DUPLICATE KEY UPDATE
        material_type = IF(source = 'SAP_GROUP', 'CAR', material_type),
        description   = IF(source = 'SAP_GROUP', x.source_description, description),
        updated_by    = IF(source = 'SAP_GROUP', CURRENT_USER(), updated_by),
        source        = IF(source = 'SAP_GROUP', 'MATERIAL_CODE', source);


    /*
    ========================================================
    4. PEÇAS PELO GRUPO DO SAP (INCREMENTAL)
    ========================================================
    material_group_2 = 'B1' é o grupo de peça no SAP (medido em
    13/11/2026: 9.616 materiais B1, nenhum deles no Material Code
    exceto 3 casos de conflito, que ficam como CAR e caem na
    fallback pela regra de chassi).

    INSERT IGNORE: qualquer linha já existente (de qualquer fonte)
    vence. Só entra material que ainda não está na tabela.
    ========================================================
    */

    INSERT IGNORE INTO bp_datalake.dim_material_classification (
        material,
        material_type,
        source,
        description,
        updated_by
    )
    SELECT
        TRIM(s.material),
        'PART',
        'SAP_GROUP',
        MAX(LEFT(TRIM(s.description), 255)),
        CURRENT_USER()
    FROM bp_datalake.silver_zsdbil17_outbound_movements AS s
    WHERE s.chassis_rule IS NULL
      AND s.material_group_2 = 'B1'
      AND NULLIF(TRIM(s.material), '') IS NOT NULL
    GROUP BY TRIM(s.material);

END $$

DELIMITER ;
