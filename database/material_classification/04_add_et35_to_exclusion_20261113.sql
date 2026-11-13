-- ============================================================
-- dim_zsdbil17_material_exclusion - ET35 (13/11/2026)
-- ============================================================
-- Primeiro caso da silver_zsdbil17_chassis_fallback depois do
-- deploy do ADR-016: 18500173-00 CAMINHAO ELETRICO ET35 BYD caiu
-- em FALLBACK_MATERIAL_UNCLASSIFIED. Decisão do Bruno em
-- 13/11/2026: é caminhão, vai para a exclusão (igual ao ET5).
--
-- Efeito na próxima pipeline:
--   - sp_silver_z17_vehicle_type reclassifica as linhas UNKNOWN;
--   - sp_refresh_dim_material_classification grava BUS_TRUCK;
--   - sp_silver_z17_chassis_resolution reavalia a linha FALLBACK_*
--     (vira NOT_CAR_BUS_TRUCK) e ela sai da fallback.
-- Idempotente (NOT EXISTS).
-- ============================================================

INSERT INTO bp_datalake.dim_zsdbil17_material_exclusion (
    material,
    vehicle_category,
    description,
    active,
    created_at
)
SELECT '18500173-00', 'TRUCK', 'CAMINHAO ELETRICO ET35 BYD', TRUE, NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM bp_datalake.dim_zsdbil17_material_exclusion
    WHERE material = '18500173-00'
);

SELECT material, vehicle_category, description, active
FROM bp_datalake.dim_zsdbil17_material_exclusion
WHERE material IN ('18500173-00', '20633341-00', '21196208-00');
