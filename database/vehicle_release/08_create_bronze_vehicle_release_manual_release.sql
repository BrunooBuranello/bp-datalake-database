-- ============================================================
-- TABELA: bp_datalake.bronze_vehicle_release_manual_release
-- CAMADA: Bronze (registro feito por pessoa no app)
--
-- OBJETIVO:
-- Liberações registradas no app para NFs SEM pedido no CRM (casos
-- que o time BP libera offline). Substitui a anotação na planilha:
-- quem liberou, quando e por quê.
--
-- QUEM GRAVA: só a procedure sp_register_vehicle_release_manual
-- (botão "Registrar liberação", permissão execute_vehicle_release).
-- QUEM LÊ: sp_sync_bronze_vehicle_release, que mantém a NF como
-- RELEASED (released_source = APP) enquanto a linha estiver ativa.
--
-- CUIDADOS:
-- - Uma linha por NF (UNIQUE na chave chassi + NF + data + planta),
--   exceção à regra "Bronze sem UNIQUE", como na foto atual.
-- - Nunca apagar: para desfazer, is_active = 'NO' + revoked_* (por
--   enquanto só via SQL, com o motivo).
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_vehicle_release_manual_release (

    id BIGINT NOT NULL AUTO_INCREMENT,

    chassis_serial_number VARCHAR(17) NOT NULL,
    invoice_number VARCHAR(9) NOT NULL,
    issuance_date DATE NOT NULL,
    plant_code VARCHAR(10) NOT NULL,

    released_by VARCHAR(150) NOT NULL
        COMMENT 'Usuário do app que registrou a liberação',
    released_at DATETIME NOT NULL,
    release_reason VARCHAR(500) NOT NULL
        COMMENT 'Motivo informado (obrigatório)',

    is_active CHAR(3) NOT NULL DEFAULT 'YES'
        COMMENT 'NO = liberação desfeita (nunca apagar)',
    revoked_by VARCHAR(150) NULL,
    revoked_at DATETIME NULL,
    revoke_reason VARCHAR(500) NULL,

    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_vehicle_release_manual_key (
        chassis_serial_number, invoice_number, issuance_date, plant_code
    ),
    CONSTRAINT chk_vehicle_release_manual_active
        CHECK (is_active IN ('YES', 'NO'))
)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Liberação registrada no app para NF sem pedido no CRM';
