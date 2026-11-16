-- ============================================================
-- ALTER: bp_datalake.bronze_vehicle_release
-- CAMADA: Bronze
--
-- OBJETIVO (16/11/2026, ADR-010 do app vehicle_release):
-- Guardar a data da liberação MANUAL na foto atual, para a tela
-- mostrar e filtrar por ela:
-- - controle antigo (planilha): data_de_liberacao de
--   bronze_chassis_released_to_logistics;
-- - app (lote ou offline): released_at de
--   bronze_vehicle_release_manual_release.
-- Liberação feita no CRM fica SEM data: o CRM não grava quando o
-- pedido virou Pending Factory Release (decisão do Bruno).
--
-- Só ADD COLUMN + índice. A procedure 06 recriada preenche a coluna
-- na próxima execução; a 06 anterior simplesmente não a usa.
-- ============================================================

ALTER TABLE bp_datalake.bronze_vehicle_release
    ADD COLUMN release_date DATE NULL
        COMMENT 'Data da liberação manual (planilha antiga ou app); vazia quando liberado no CRM'
        AFTER released_source,
    ADD INDEX idx_vehicle_release_release_date (release_date);
