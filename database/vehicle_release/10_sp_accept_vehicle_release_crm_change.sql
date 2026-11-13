-- ============================================================
-- PROCEDURE: bp_datalake.sp_accept_vehicle_release_crm_change
-- CAMADA: Bronze
--
-- OBJETIVO:
-- Uma pessoa conferiu a alteração do pedido no CRM (alerta
-- crm_change_alert) e aceita a nova situação: a foto do CRM é
-- congelada de novo com os valores atuais e o alerta some.
--
-- QUEM CHAMA: botão "Aceitar alteração do CRM" do app (permissão
-- execute_vehicle_release), com o usuário logado e o comentário.
--
-- EFEITO (transação única):
-- - crm_snapshot_* = CRM atual da foto; crm_change_alert = NULL;
-- - NF bloqueada (CRM_CHANGED) volta para WAITING_CRM com o motivo
--   "alteração aceita"; a próxima execução recalcula o status real;
-- - evento CRM_CHANGE_ACCEPTED no audit_history, com o que mudou.
--
-- Usa o mesmo GET_LOCK da sync (espera até 10 s).
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_accept_vehicle_release_crm_change;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_accept_vehicle_release_crm_change(
    IN p_chassis_serial_number VARCHAR(17),
    IN p_invoice_number VARCHAR(9),
    IN p_issuance_date DATE,
    IN p_plant_code VARCHAR(10),
    IN p_accepted_by VARCHAR(150),
    IN p_comment VARCHAR(500)
)
BEGIN

    DECLARE c_lock_name VARCHAR(64) DEFAULT 'bp_datalake.vehicle_release_sync';
    DECLARE v_lock_acquired INT DEFAULT 0;
    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_comment VARCHAR(500) DEFAULT NULL;
    DECLARE v_status VARCHAR(30) DEFAULT NULL;
    DECLARE v_alert VARCHAR(500) DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF v_lock_acquired = 1 THEN
            DO RELEASE_LOCK(c_lock_name);
        END IF;
        RESIGNAL;
    END;

    SET v_comment = NULLIF(TRIM(p_comment), '');

    IF NULLIF(TRIM(p_accepted_by), '') IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Usuário obrigatório para aceitar a alteração.';
    END IF;

    IF v_comment IS NULL OR CHAR_LENGTH(v_comment) < 10 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Informe o que foi conferido (mínimo 10 caracteres).';
    END IF;

    SET v_lock_acquired = COALESCE(GET_LOCK(c_lock_name, 10), 0);
    IF v_lock_acquired <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A validação da Liberação está rodando agora. Tente de novo em alguns minutos.';
    END IF;

    START TRANSACTION;

    SELECT release_status, crm_change_alert
    INTO v_status, v_alert
    FROM bp_datalake.bronze_vehicle_release
    WHERE chassis_serial_number = p_chassis_serial_number
      AND invoice_number = p_invoice_number
      AND issuance_date = p_issuance_date
      AND plant_code = p_plant_code
    FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NF não encontrada na Liberação.';
    END IF;

    IF v_alert IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Esta NF não tem alteração do CRM para aceitar.';
    END IF;

    UPDATE bp_datalake.bronze_vehicle_release
    SET
        crm_snapshot_order_no = crm_order_no,
        crm_snapshot_order_status = crm_order_status,
        crm_snapshot_order_sub_status = crm_order_sub_status,
        crm_snapshot_vehicle_model_code = crm_vehicle_model_code,
        crm_snapshot_config_no = crm_config_no,
        crm_snapshot_exterior_color_code = crm_exterior_color_code,
        crm_snapshot_interior_color_code = crm_interior_color_code,
        crm_snapshot_at = v_now,
        crm_change_alert = NULL,
        -- status_since antes de release_status (esquerda para a direita).
        status_since = IF(release_status = 'CRM_CHANGED', v_now, status_since),
        release_status_reason = IF(
            release_status = 'CRM_CHANGED',
            'Alteração do CRM aceita; aguardando a próxima validação',
            release_status_reason
        ),
        release_status = IF(release_status = 'CRM_CHANGED', 'WAITING_CRM', release_status)
    WHERE chassis_serial_number = p_chassis_serial_number
      AND invoice_number = p_invoice_number
      AND issuance_date = p_issuance_date
      AND plant_code = p_plant_code;

    INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
        run_id, triggered_by,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        change_type, old_status, new_status, status_reason,
        crm_change_alert, changed_at
    )
    VALUES (
        0, TRIM(p_accepted_by),
        p_chassis_serial_number, p_invoice_number, p_issuance_date, p_plant_code,
        'CRM_CHANGE_ACCEPTED', v_status,
        IF(v_status = 'CRM_CHANGED', 'WAITING_CRM', v_status),
        v_comment, v_alert, v_now
    );

    COMMIT;

    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

END$$

DELIMITER ;
