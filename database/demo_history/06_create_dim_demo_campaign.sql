-- ============================================================
-- ZSDBIL17 - DEMO HISTORY
-- 06 - CAMPANHAS COMERCIAIS DO CICLO DEMO
-- ============================================================
-- Objetivo:
-- Guardar as campanhas que alteram o prazo padrão do ciclo
-- DEMO (aviso no dia 20 e vencimento após o dia 30).
--
-- Quem usa:
-- bp_datalake.sp_gold_z17_demo_apply_campaign, que roda na
-- pipeline depois do enriquecimento de modelo e reescreve
-- warning_date, due_date e demo_status dos ciclos elegíveis.
--
-- Elegibilidade (todas as condições):
-- 1. active = 1;
-- 2. data de emissão da NF DEMO entre issuance_from e
--    issuance_to (NULL = sem fim). A vigência é pela emissão
--    e não pela data de hoje: um DEMO emitido dentro da janela
--    leva o prazo da campanha até o fim do ciclo, mesmo depois
--    que a campanha termina;
-- 3. model_simplified do ciclo começa com
--    model_simplified_prefix (ex.: 'SHARK' cobre SHARK GS e
--    SHARK GL da Material Code);
-- 4. model_year preenchido -> o material precisa ter esse
--    ano_modelo na bronze_vehicle_material_code.
--
-- Desempate:
-- Mais de uma campanha elegível -> maior priority vence;
-- empate -> menor campaign_code (ordem alfabética).
--
-- Cuidado:
-- Alterar uma linha muda o prazo dos ciclos abertos na
-- próxima execução da pipeline. Para encerrar uma campanha
-- sem apagar o histórico, use active = 0.
-- Este script é idempotente.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.dim_demo_campaign (

    id INT NOT NULL AUTO_INCREMENT,

    -- Código estável gravado na Gold (ex.: SHARK_MY2026_60D).
    campaign_code VARCHAR(50) NOT NULL,

    -- Nome exibido na tela, no Excel e no aviso por grupo.
    campaign_name VARCHAR(150) NOT NULL,

    -- Comunicado de origem (ex.: CV 129/2026).
    reference_document VARCHAR(100) NULL,

    -- Critério de modelo: prefixo do model_simplified.
    model_simplified_prefix VARCHAR(100) NOT NULL,

    -- Ano-modelo exigido (NULL = qualquer ano-modelo).
    model_year VARCHAR(10) NULL,

    -- Janela pela data de emissão da NF DEMO.
    issuance_from DATE NOT NULL,
    issuance_to DATE NULL,

    -- Prazos contados a partir da emissão (emissão = dia 0).
    warning_days SMALLINT NOT NULL DEFAULT 20,
    due_days SMALLINT NOT NULL,

    -- Maior número vence quando duas campanhas se aplicam.
    priority INT NOT NULL DEFAULT 0,

    active TINYINT(1) NOT NULL DEFAULT 1,

    notes VARCHAR(500) NULL,

    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,
    updated_by VARCHAR(100) NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uk_demo_campaign_code (campaign_code),
    KEY idx_demo_campaign_active (active, issuance_from),

    -- O aviso nunca pode vir depois do vencimento.
    CONSTRAINT chk_demo_campaign_days
        CHECK (warning_days >= 0 AND due_days >= warning_days),

    CONSTRAINT chk_demo_campaign_window
        CHECK (issuance_to IS NULL OR issuance_to >= issuance_from)

)
ENGINE = InnoDB
COMMENT = 'Campanhas comerciais que alteram o prazo do ciclo DEMO';


-- ============================================================
-- SEED - PLANO DE AÇÃO SHARK MY2026 (CV 129/2026)
-- ============================================================
-- Unidades de demonstração Shark MY2026 em comodato ficam
-- 60 dias em demonstração (out-dez/2026). O aviso continua no
-- dia 20 (decisão do BP); só o vencimento vai para 60 dias.
-- Na Material Code o modelo aparece como SHARK GS e SHARK GL.
-- ============================================================

INSERT INTO bp_datalake.dim_demo_campaign (
    campaign_code,
    campaign_name,
    reference_document,
    model_simplified_prefix,
    model_year,
    issuance_from,
    issuance_to,
    warning_days,
    due_days,
    priority,
    active,
    notes,
    updated_by
)
VALUES (
    'SHARK_MY2026_60D',
    'Shark MY2026 - 60 dias',
    'CV 129/2026',
    'SHARK',
    '2026',
    '2026-10-01',
    '2026-12-31',
    20,
    60,
    100,
    1,
    'Plano de Ação Shark MY2026: demonstração de 60 dias para DEMO emitido de out a dez/2026.',
    CURRENT_USER()
)
ON DUPLICATE KEY UPDATE
    campaign_name = VALUES(campaign_name),
    reference_document = VALUES(reference_document),
    model_simplified_prefix = VALUES(model_simplified_prefix),
    model_year = VALUES(model_year),
    issuance_from = VALUES(issuance_from),
    issuance_to = VALUES(issuance_to),
    warning_days = VALUES(warning_days),
    due_days = VALUES(due_days),
    priority = VALUES(priority),
    active = VALUES(active),
    notes = VALUES(notes),
    updated_by = VALUES(updated_by);
