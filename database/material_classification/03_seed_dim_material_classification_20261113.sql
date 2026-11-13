-- ============================================================
-- CARGA INICIAL - dim_material_classification (13/11/2026)
-- ============================================================
-- Rodar UMA vez, na ordem do deploy (ADR-016 do sap_service):
--   1. 01_create_dim_material_classification.sql
--   2. silver/08_alter_silver_zsdbil17_add_chassis_resolution.sql
--   3. 02_sp_refresh_dim_material_classification.sql
--   4. ESTE arquivo
--
-- Decisões do Bruno em 13/11/2026, a partir da lista de materiais
-- sem grupo no SAP (z17_materiais_sem_grupo.csv, 5.061 materiais):
--   - 21196208-00 CHASSI ONIBUS ELETRICO D9W  -> exclusão (BUS)
--   - 20633341-00 AI VEICULO ELETRICO ET5     -> exclusão (TRUCK)
--   - 18903737-00 VEICULO DE MANUTENCAO INTEGRADA - MIV -> OTHER
--   - 20813523-00 ZFM SONG 105KM PRETO        -> NÃO classificar:
--     é carro sem cadastro no Material Code e deve aparecer na
--     fallback até ser cadastrado.
--   - demais materiais da lista -> PART (descrições de peça; o
--     material nunca teve chassi no histórico)
-- ============================================================


-- ------------------------------------------------------------
-- 1. Ônibus / caminhão na exclusão (o sp_silver_z17_vehicle_type
--    reclassifica as linhas UNKNOWN desses materiais na próxima
--    pipeline).
-- ------------------------------------------------------------

INSERT INTO bp_datalake.dim_zsdbil17_material_exclusion (
    material,
    vehicle_category,
    description,
    active,
    created_at
)
SELECT '21196208-00', 'BUS', 'CHASSI ONIBUS ELETRICO D9W', TRUE, NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM bp_datalake.dim_zsdbil17_material_exclusion
    WHERE material = '21196208-00'
);

INSERT INTO bp_datalake.dim_zsdbil17_material_exclusion (
    material,
    vehicle_category,
    description,
    active,
    created_at
)
SELECT '20633341-00', 'TRUCK', 'AI VEICULO ELETRICO ET5', TRUE, NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM bp_datalake.dim_zsdbil17_material_exclusion
    WHERE material = '20633341-00'
);


-- ------------------------------------------------------------
-- 2. Carga automática: exclusão, Material Code e, como todas as
--    linhas da Silver ainda estão com chassis_rule NULL, o grupo
--    B1 do SAP do histórico inteiro (resolve ~5.088 materiais que
--    vinham sem grupo nos arquivos manuais).
-- ------------------------------------------------------------

CALL bp_datalake.sp_refresh_dim_material_classification();


-- ------------------------------------------------------------
-- 3. Decisão manual: MIV = OTHER.
-- ------------------------------------------------------------

INSERT INTO bp_datalake.dim_material_classification (
    material, material_type, source, description, notes, updated_by
)
VALUES (
    '18903737-00', 'OTHER', 'MANUAL',
    'VEICULO DE MANUTENCAO INTEGRADA - MIV',
    'Decisão do Bruno em 13/11/2026: não é carro de venda',
    'bruno.buranello'
)
ON DUPLICATE KEY UPDATE
    material_type = 'OTHER',
    notes = VALUES(notes),
    updated_by = VALUES(updated_by),
    source = 'MANUAL';


-- ------------------------------------------------------------
-- 4. Carga revisada: materiais sem classificação que aparecem com
--    VIN em linha de CFOP de venda e nunca tiveram grupo B1/G1
--    nem chassi do SAP = peças (lista revisada em 13/11/2026).
--    Fica com source SEED_20261113 para poder ser identificada e,
--    se preciso, desfeita:
--        DELETE FROM bp_datalake.dim_material_classification
--        WHERE source = 'SEED_20261113';
-- ------------------------------------------------------------

-- Materiais que já apareceram como veículo (G1) ou com chassi do
-- SAP em alguma linha: ficam FORA da carga. Tabela temporária para
-- varrer a Silver uma vez só (um NOT EXISTS por material seria uma
-- varredura completa para cada um dos ~5 mil materiais).
DROP TEMPORARY TABLE IF EXISTS tmp_seed_vehicle_like_materials;

CREATE TEMPORARY TABLE tmp_seed_vehicle_like_materials (
    material VARCHAR(50)
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_0900_ai_ci NOT NULL,
    PRIMARY KEY (material)
) ENGINE = InnoDB;

INSERT IGNORE INTO tmp_seed_vehicle_like_materials (material)
SELECT DISTINCT LEFT(TRIM(o.material), 50)
FROM bp_datalake.silver_zsdbil17_outbound_movements AS o
WHERE NULLIF(TRIM(o.material), '') IS NOT NULL
  AND (
        TRIM(o.material_group_2) = 'G1'
     OR NULLIF(TRIM(o.chassis_serial_number), '') IS NOT NULL
      );

INSERT IGNORE INTO bp_datalake.dim_material_classification (
    material, material_type, source, description, notes, updated_by
)
SELECT
    TRIM(s.material),
    'PART',
    'SEED_20261113',
    MAX(LEFT(TRIM(s.description), 255)),
    'Sem grupo no SAP e sem chassi no histórico; lista revisada em 13/11/2026',
    'bruno.buranello'
FROM bp_datalake.silver_zsdbil17_outbound_movements AS s
LEFT JOIN bp_datalake.dim_material_classification AS d
    ON d.material = TRIM(s.material)
LEFT JOIN tmp_seed_vehicle_like_materials AS v
    ON v.material = TRIM(s.material)
WHERE NULLIF(TRIM(s.chassis_serial_number), '') IS NULL
  AND s.cfop_car = 'YES'
  AND COALESCE(TRIM(s.material_group_2), '') NOT IN ('B1', 'G1')
  AND (
        REGEXP_LIKE(TRIM(COALESCE(s.chassi_do_veiculo, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
     OR REGEXP_LIKE(TRIM(COALESCE(s.customer_reference, '')), '^[A-HJ-NPR-Z0-9]{17}$', 'c')
      )
  AND NULLIF(TRIM(s.material), '') IS NOT NULL
  -- ZFM SONG: carro sem cadastro, fica para a fallback.
  AND TRIM(s.material) <> '20813523-00'
  -- Já classificado por outra fonte (Material Code, exclusão, B1, MANUAL).
  AND d.material IS NULL
  -- Nunca visto como veículo (G1) nem com chassi do SAP.
  AND v.material IS NULL
GROUP BY TRIM(s.material);

DROP TEMPORARY TABLE IF EXISTS tmp_seed_vehicle_like_materials;


-- ------------------------------------------------------------
-- 5. Conferência (esperado em 13/11/2026: ~5.057 SEED_20261113,
--    1 MANUAL, 2 novas na exclusão).
-- ------------------------------------------------------------

SELECT source, material_type, COUNT(*) AS materials
FROM bp_datalake.dim_material_classification
GROUP BY source, material_type
ORDER BY source, material_type;
