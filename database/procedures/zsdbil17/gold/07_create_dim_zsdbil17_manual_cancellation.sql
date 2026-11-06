-- ============================================================
-- ZSDBIL17 - GOLD
-- 07 - CANCELAMENTO MANUAL DE FATURAMENTO (PALIATIVO)
-- ============================================================
-- Objetivo:
-- Guardar as NFs que o time de BP confirmou como canceladas ou
-- devolvidas, mas que a ZSDBIL17 ainda não marca como
-- CANCELLED. Enquanto os cancelamentos não forem estruturados,
-- esta lista tira essas NFs do faturamento (Gold).
--
-- Quem grava:
-- App Django "cancellations" (BYD Sales Operation). Usuário
-- cola chassi + NF + data do faturamento original. O app
-- completa a NF com zeros à esquerda (9 dígitos, formato da
-- Silver), confere na Silver que existe exatamente uma NF de
-- veículo com chassi + NF + data e grava aqui a planta dessa NF
-- (plant_code), que o usuário não precisa saber.
--
-- Quem usa:
-- bp_datalake.sp_z17_apply_manual_cancellation (08), no fim
-- da pipeline Z17:
--   Silver -> manual_cancellation = 'YES'
--   Gold   -> DELETE da linha chassi + NF + data + planta
--
-- Regras:
-- 1. Chave = chassi + NF + data de emissão + planta (ADR-004 do
--    app cancellations). Só chassi + NF não basta: cada CNPJ da
--    BYD tem a própria numeração de NF, e o mesmo chassi pode
--    receber NFs de mesmo número de CNPJs diferentes (8.081
--    combinações chassi + NF ambíguas na Silver em 06/11/2026;
--    com data + planta sobram 3, do histórico antigo, que o app
--    recusa). Uma NF nova do mesmo chassi nunca casa e volta para
--    a Gold normalmente.
-- 2. Nunca apagar linha: para desfazer, o app grava active = 0
--    (com deactivated_by / deactivated_at) e a próxima carga
--    devolve a NF para a Gold. Registrar de novo a mesma NF
--    reativa a linha (active = 1).
-- 3. Toda mudança gera linha na tabela de auditoria abaixo,
--    na mesma transação.
--
-- Collation:
-- utf8mb4_0900_ai_ci, a mesma usada nas comparações com a
-- Silver (ver 07_sp_silver_z17_vehicle_type), para o JOIN não
-- falhar com erro 1267.
--
-- Este script é idempotente.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.dim_zsdbil17_manual_cancellation (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- VIN de 17 caracteres, em maiúsculas.
    chassis_serial_number VARCHAR(17) NOT NULL,

    -- Data de emissão da NF cancelada, informada pelo usuário.
    original_issuance_date DATE NOT NULL,

    -- NF informada pelo usuário, gravada com 9 dígitos (zeros à
    -- esquerda), no mesmo formato da Silver e da Gold.
    invoice_number VARCHAR(50) NOT NULL,

    -- Planta da NF, buscada na Silver no registro (o usuário não
    -- informa). Faz parte da chave: separa NFs de mesmo número
    -- emitidas por estabelecimentos diferentes.
    plant_code VARCHAR(10) NOT NULL,

    -- first_seen_at da Silver no momento do registro. Só para
    -- auditoria: histórico anterior à reconciliação não tem valor.
    invoice_first_seen_at DATETIME NULL,

    -- Observação livre, opcional.
    observation VARCHAR(500) NULL,

    -- Usuário do BYD Sales Operation que registrou.
    inserted_by VARCHAR(150) NOT NULL,

    -- Data e hora do registro (automática).
    loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- 1 = vale para a pipeline; 0 = desativado (desfeito).
    active TINYINT(1) NOT NULL DEFAULT 1,

    deactivated_by VARCHAR(150) NULL,
    deactivated_at DATETIME NULL,

    PRIMARY KEY (id),

    UNIQUE KEY uk_manual_cancellation_invoice_key (
        chassis_serial_number,
        invoice_number,
        original_issuance_date,
        plant_code
    ),

    KEY idx_manual_cancellation_active (active),
    KEY idx_manual_cancellation_loaded_at (loaded_at),

    -- Bloqueia chassi vazio ou fora do padrão de 17 caracteres.
    CONSTRAINT chk_manual_cancellation_chassis
        CHECK (CHAR_LENGTH(TRIM(chassis_serial_number)) = 17),

    CONSTRAINT chk_manual_cancellation_invoice
        CHECK (TRIM(invoice_number) <> ''),

    CONSTRAINT chk_manual_cancellation_plant
        CHECK (TRIM(plant_code) <> ''),

    CONSTRAINT chk_manual_cancellation_inserted_by
        CHECK (TRIM(inserted_by) <> ''),

    -- Desativação sempre registra quem e quando.
    CONSTRAINT chk_manual_cancellation_deactivation
        CHECK (
            active = 1
            OR (deactivated_by IS NOT NULL AND deactivated_at IS NOT NULL)
        )

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'NFs de faturamento canceladas manualmente (paliativo); retiradas da Gold Z17 pela sp_z17_apply_manual_cancellation';


-- ============================================================
-- AUDITORIA
-- ============================================================
-- Append-only: o app só faz INSERT aqui. Mesmo padrão de
-- bronze_vehicle_material_code_audit_history (Material Code).
--
-- action_type:
--   REGISTER   -> registro criado (field_name = NULL)
--   DEACTIVATE -> active 1 -> 0 (field_name = 'active')
--   REACTIVATE -> active 0 -> 1 (field_name = 'active'), quando
--                 a mesma NF é registrada de novo depois de
--                 desativada (a UNIQUE da chave impede uma
--                 segunda linha; o histórico fica na auditoria)
--
-- request_id agrupa as linhas de um mesmo lote/clique.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.dim_zsdbil17_manual_cancellation_audit_history (

    id BIGINT NOT NULL AUTO_INCREMENT,

    -- id da dim_zsdbil17_manual_cancellation (FK lógica).
    manual_cancellation_id BIGINT NOT NULL,

    -- Copiados para a auditoria continuar legível sozinha.
    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(50) NOT NULL,
    original_issuance_date DATE NULL,
    plant_code VARCHAR(10) NULL,

    action_type VARCHAR(20) NOT NULL,

    field_name VARCHAR(64) NULL,
    old_value VARCHAR(500) NULL,
    new_value VARCHAR(500) NULL,

    changed_by VARCHAR(150) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    request_id CHAR(36) NOT NULL,

    PRIMARY KEY (id),

    KEY idx_manual_cancellation_audit_record (manual_cancellation_id, changed_at),
    KEY idx_manual_cancellation_audit_request (request_id),

    CONSTRAINT chk_manual_cancellation_audit_action
        CHECK (action_type IN ('REGISTER', 'DEACTIVATE', 'REACTIVATE'))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Auditoria append-only da dim_zsdbil17_manual_cancellation';
