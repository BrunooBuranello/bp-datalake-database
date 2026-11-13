-- ============================================================
-- TABELA: dim_material_classification
-- CAMADA: Dimensão (referência)
--
-- OBJETIVO:
-- Responder, num lugar só, "que tipo é este material?":
-- carro, peça, ônibus/caminhão ou outro. É usada pela regra de
-- chassi da Silver da Z17 (sp_silver_z17_chassis_resolution) e
-- serve de apoio para rastreamento e para entender os casos da
-- silver_zsdbil17_chassis_fallback (ADR-016 do sap_service).
--
-- ORIGEM DE CADA LINHA (coluna source), em ordem de prioridade:
--   MANUAL         decisão do time, digitada; nunca é sobrescrita
--                  pelo processo automático.
--   SEED_20261113  carga inicial revisada pelo Bruno em 13/11/2026
--                  (materiais sem grupo no SAP, sem chassi no
--                  histórico e com descrição de peça). Tratada como
--                  MANUAL: o processo automático não mexe.
--   EXCLUSION      dim_zsdbil17_material_exclusion (ônibus/caminhão).
--   MATERIAL_CODE  bronze_vehicle_material_code (portal Material
--                  Code), fonte oficial dos carros.
--   SAP_GROUP      grupo de material do SAP visto na Silver
--                  (material_group_2 = 'B1' -> peça).
--
-- ESTRATÉGIA DE CARGA:
-- - sp_refresh_dim_material_classification roda a cada pipeline:
--   refaz as linhas EXCLUSION e MATERIAL_CODE (pequenas) e acrescenta
--   SAP_GROUP só dos materiais novos. MANUAL e SEED ficam intactas.
-- - Material Code continua sendo a fonte dos carros: esta tabela
--   LÊ o Material Code, ninguém copia carros à mão para cá.
--
-- CHAVE:
-- PRIMARY KEY (material), com justificativa: cada material tem um
-- único tipo. Uma segunda linha do mesmo material seria duas
-- respostas diferentes para a mesma pergunta.
--
-- COLLATION utf8mb4_0900_ai_ci: igual à Silver da Z17 e à
-- dim_zsdbil17_material_exclusion, para o JOIN usar o índice.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.dim_material_classification (

    -- Código do material no SAP (ex.: 19864724-00), sem espaços.
    material VARCHAR(50)
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_0900_ai_ci NOT NULL,

    -- CAR, PART, BUS_TRUCK ou OTHER.
    material_type VARCHAR(20)
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_0900_ai_ci NOT NULL,

    -- MANUAL, SEED_20261113, EXCLUSION, MATERIAL_CODE ou SAP_GROUP.
    source VARCHAR(20)
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_0900_ai_ci NOT NULL,

    -- Descrição do material (da fonte ou da Silver), para leitura.
    description VARCHAR(255) NULL,

    -- Motivo da decisão manual (obrigatório na prática para MANUAL).
    notes VARCHAR(500) NULL,

    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),

    -- Usuário do MySQL ou nome de quem decidiu (linhas MANUAL).
    updated_by VARCHAR(100) NULL,

    PRIMARY KEY (material),

    INDEX idx_dim_material_classification_type (material_type)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci

COMMENT = 'Tipo de cada material (CAR, PART, BUS_TRUCK, OTHER) consolidado de Material Code, exclusão, grupo SAP e decisões manuais';
