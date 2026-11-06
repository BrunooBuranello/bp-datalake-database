-- ============================================================
-- ZSDBIL17 - DEMO HISTORY
-- 08 - CAMPANHA POR LISTA DE CHASSIS, PRAZO FIXO E VIGÊNCIA
-- ============================================================
-- Objetivo:
-- Permitir campanhas que não dependem de modelo: a campanha
-- vale para uma lista explícita de chassis, com vencimento em
-- data fixa e uma vigência pela data de hoje (ADR-042 do app
-- demo_notifications).
--
-- O que muda em dim_demo_campaign (só acréscimos):
-- - match_type: 'MODEL' (regra do Shark, padrão) ou
--   'CHASSIS_LIST' (chassis de dim_demo_campaign_chassis);
-- - fixed_due_date: vencimento fixo; quando preenchido vence
--   o due_days;
-- - valid_from / valid_to: vigência pela data de HOJE
--   (NULL = sem limite). Fora da vigência a campanha não se
--   aplica e o ciclo volta ao prazo padrão na próxima
--   execução. Não confundir com issuance_from/issuance_to,
--   que dizem quais NFs DEMO entram (pela emissão);
-- - message_before_table: texto exibido no aviso por grupo
--   acima da relação dos chassis da campanha (NULL = sem
--   bloco próprio, como o Shark);
-- - model_simplified_prefix e due_days passam a aceitar NULL,
--   porque a campanha por lista não usa modelo e pode usar
--   prazo fixo. A CHECK chk_demo_campaign_match exige os
--   campos certos para cada tipo.
--
-- Nova tabela dim_demo_campaign_chassis:
-- chassis de cada campanha CHASSIS_LIST. FK para a campanha
-- impede chassi órfão; UNIQUE impede o mesmo chassi duas
-- vezes na mesma campanha. Um chassi pode estar em mais de
-- uma campanha: a priority decide (ver 06 e 07).
--
-- Cuidados:
-- - Idempotente: pode rodar mais de uma vez.
-- - Rodar ANTES do deploy do app que lê message_before_table.
-- - Nenhum dado existente é alterado; o Shark segue como
--   MODEL com os mesmos valores.
-- ============================================================


-- ------------------------------------------------------------
-- 1. COLUNAS NOVAS (MySQL 8 não tem ADD COLUMN IF NOT EXISTS)
-- ------------------------------------------------------------

DROP PROCEDURE IF EXISTS bp_datalake.tmp_add_demo_campaign_columns;

DELIMITER $$

CREATE PROCEDURE bp_datalake.tmp_add_demo_campaign_columns()
BEGIN

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND column_name = 'match_type'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD COLUMN match_type VARCHAR(20) NOT NULL DEFAULT 'MODEL'
                AFTER reference_document;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND column_name = 'fixed_due_date'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD COLUMN fixed_due_date DATE NULL AFTER due_days;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND column_name = 'valid_from'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD COLUMN valid_from DATE NULL AFTER fixed_due_date,
            ADD COLUMN valid_to DATE NULL AFTER valid_from;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND column_name = 'message_before_table'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD COLUMN message_before_table TEXT NULL AFTER notes;
    END IF;

    -- Campanha por lista não usa modelo e pode usar prazo fixo.
    ALTER TABLE bp_datalake.dim_demo_campaign
        MODIFY COLUMN model_simplified_prefix VARCHAR(100) NULL,
        MODIFY COLUMN due_days SMALLINT NULL;

    -- Campos obrigatórios por tipo de campanha.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND constraint_name = 'chk_demo_campaign_match'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD CONSTRAINT chk_demo_campaign_match CHECK (
                (
                    match_type = 'MODEL'
                    AND model_simplified_prefix IS NOT NULL
                    AND due_days IS NOT NULL
                )
                OR (
                    match_type = 'CHASSIS_LIST'
                    AND (due_days IS NOT NULL OR fixed_due_date IS NOT NULL)
                )
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_schema = 'bp_datalake'
          AND table_name = 'dim_demo_campaign'
          AND constraint_name = 'chk_demo_campaign_validity'
    ) THEN
        ALTER TABLE bp_datalake.dim_demo_campaign
            ADD CONSTRAINT chk_demo_campaign_validity CHECK (
                valid_from IS NULL
                OR valid_to IS NULL
                OR valid_to >= valid_from
            );
    END IF;

END$$

DELIMITER ;

CALL bp_datalake.tmp_add_demo_campaign_columns();

DROP PROCEDURE IF EXISTS bp_datalake.tmp_add_demo_campaign_columns;


-- ------------------------------------------------------------
-- 2. CHASSIS DAS CAMPANHAS POR LISTA
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bp_datalake.dim_demo_campaign_chassis (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- Campanha a que o chassi pertence (dim_demo_campaign).
    campaign_code VARCHAR(50) NOT NULL,

    -- Chassi com 17 caracteres, em maiúsculas (a carga normaliza).
    chassis_serial_number VARCHAR(17) NOT NULL,

    -- Auditoria da carga (comando load_demo_campaign_chassis).
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100) NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uk_demo_campaign_chassis (campaign_code, chassis_serial_number),
    KEY idx_demo_campaign_chassis_chassis (chassis_serial_number),

    CONSTRAINT fk_demo_campaign_chassis_campaign
        FOREIGN KEY (campaign_code)
        REFERENCES bp_datalake.dim_demo_campaign (campaign_code)

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Chassis das campanhas DEMO por lista (match_type = CHASSIS_LIST)';


-- ------------------------------------------------------------
-- 3. CONFERÊNCIA
-- ------------------------------------------------------------

SELECT campaign_code, match_type, model_simplified_prefix, due_days,
       fixed_due_date, valid_from, valid_to,
       message_before_table IS NOT NULL AS has_message
FROM bp_datalake.dim_demo_campaign;
