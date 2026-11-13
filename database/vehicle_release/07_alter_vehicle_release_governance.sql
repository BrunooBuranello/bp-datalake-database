-- ============================================================
-- ALTER: governança da Liberação de Veículos (12/11/2026)
-- CAMADA: Bronze
--
-- OBJETIVO:
-- 1. Foto do CRM congelada quando a NF fica pronta ou liberada
--    (crm_snapshot_*), para detectar pedido alterado no CRM depois
--    (crm_change_alert). Pedido do Bruno: "o CRM atualiza o pedido,
--    mas a planilha offline não, e mistura as informações".
-- 2. Alerta de controle da liberação feita no CRM (control_alert):
--    o CRM liberou, mas a NF não está na BASE do Financeiro ou o
--    prazo não passa.
-- 3. Foto do evento no histórico: o que o app viu em cada mudança
--    (CRM, BASE, prazo, cliente, alertas). Crédito fica reservado
--    (credit_balance_amount) até a regra de crédito voltar.
-- 4. Totais novos na execução.
--
-- Rodar ANTES da nova versão da procedure 06 (ela grava estas
-- colunas). ADD COLUMN só acrescenta: linhas antigas ficam NULL e a
-- 1ª execução depois do deploy congela a foto sem gerar alerta.
--
-- ROLLBACK: DROP COLUMN das colunas abaixo (procedure 06 anterior
-- não as usa).
-- ============================================================

ALTER TABLE bp_datalake.bronze_vehicle_release
    ADD COLUMN crm_vehicle_model_code VARCHAR(20) NULL
        COMMENT 'CRM vehicle_model_code atual'
        AFTER crm_order_sub_status,
    ADD COLUMN crm_config_no VARCHAR(30) NULL
        COMMENT 'CRM config_no atual (versão)'
        AFTER crm_vehicle_model_code,
    ADD COLUMN crm_exterior_color_code VARCHAR(30) NULL
        COMMENT 'CRM exterior_color_code atual'
        AFTER crm_config_no,
    ADD COLUMN crm_interior_color_code VARCHAR(30) NULL
        COMMENT 'CRM interior_color_code atual'
        AFTER crm_exterior_color_code,

    ADD COLUMN crm_snapshot_order_no VARCHAR(100) NULL
        COMMENT 'Pedido do CRM congelado quando a NF ficou pronta/liberada'
        AFTER crm_loaded_at,
    ADD COLUMN crm_snapshot_order_status VARCHAR(100) NULL
        AFTER crm_snapshot_order_no,
    ADD COLUMN crm_snapshot_order_sub_status VARCHAR(100) NULL
        AFTER crm_snapshot_order_status,
    ADD COLUMN crm_snapshot_vehicle_model_code VARCHAR(20) NULL
        AFTER crm_snapshot_order_sub_status,
    ADD COLUMN crm_snapshot_config_no VARCHAR(30) NULL
        AFTER crm_snapshot_vehicle_model_code,
    ADD COLUMN crm_snapshot_exterior_color_code VARCHAR(30) NULL
        AFTER crm_snapshot_config_no,
    ADD COLUMN crm_snapshot_interior_color_code VARCHAR(30) NULL
        AFTER crm_snapshot_exterior_color_code,
    ADD COLUMN crm_snapshot_at DATETIME NULL
        COMMENT 'Quando a foto do CRM foi congelada (ou aceita de novo)'
        AFTER crm_snapshot_interior_color_code,
    ADD COLUMN crm_change_alert VARCHAR(500) NULL
        COMMENT 'O que mudou no CRM desde a foto; NULL = sem diferença'
        AFTER crm_snapshot_at,

    ADD COLUMN control_alert VARCHAR(500) NULL
        COMMENT 'Liberado no CRM sem cumprir as regras (BASE/prazo)'
        AFTER released_source;


ALTER TABLE bp_datalake.bronze_vehicle_release_audit_history
    MODIFY COLUMN change_type VARCHAR(30) NOT NULL
        COMMENT 'INSERTED, STATUS_CHANGED, ALERT_CHANGED, REMOVED_FROM_GOLD, MANUAL_RELEASE, CRM_CHANGE_ACCEPTED',
    ADD COLUMN is_rental_company CHAR(3) NULL AFTER status_reason,
    ADD COLUMN sold_to_party_cnpj CHAR(14) NULL AFTER is_rental_company,
    ADD COLUMN total_amount DECIMAL(15,2) NULL AFTER sold_to_party_cnpj,
    ADD COLUMN payment_term_days INT NULL AFTER total_amount,
    ADD COLUMN finance_base_found CHAR(3) NULL AFTER payment_term_days,
    ADD COLUMN finance_base_loaded_at DATETIME NULL AFTER finance_base_found,
    ADD COLUMN crm_match_count TINYINT NULL AFTER finance_base_loaded_at,
    ADD COLUMN crm_order_no VARCHAR(100) NULL AFTER crm_match_count,
    ADD COLUMN crm_order_status VARCHAR(100) NULL AFTER crm_order_no,
    ADD COLUMN crm_order_sub_status VARCHAR(100) NULL AFTER crm_order_status,
    ADD COLUMN crm_loaded_at DATETIME NULL AFTER crm_order_sub_status,
    ADD COLUMN control_alert VARCHAR(500) NULL AFTER crm_loaded_at,
    ADD COLUMN crm_change_alert VARCHAR(500) NULL AFTER control_alert,
    ADD COLUMN credit_balance_amount DECIMAL(15,2) NULL
        COMMENT 'Reservado: saldo de crédito visto no evento (regra de crédito parada)'
        AFTER credit_consumed_amount;


ALTER TABLE bp_datalake.bronze_vehicle_release_run_audit_history
    ADD COLUMN qty_crm_changed INT NULL
        COMMENT 'NFs bloqueadas por pedido alterado no CRM'
        AFTER qty_not_in_gold,
    ADD COLUMN qty_with_alert INT NULL
        COMMENT 'NFs com alerta de controle ou de mudança no CRM'
        AFTER qty_crm_changed,
    ADD COLUMN qty_rental_company INT NULL
        COMMENT 'NFs de locadora (VD de CNPJ cadastrado) na foto'
        AFTER qty_with_alert;
