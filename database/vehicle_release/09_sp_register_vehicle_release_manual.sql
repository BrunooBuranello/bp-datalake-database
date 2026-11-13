-- ============================================================
-- PROCEDURE: bp_datalake.sp_register_vehicle_release_manual
-- CAMADA: Bronze
--
-- OBJETIVO:
-- Registrar a liberação feita pelo time BP para uma NF SEM pedido
-- no CRM (caso offline). Substitui a anotação na planilha.
--
-- QUEM CHAMA: botão "Registrar liberação" do app (permissão
-- execute_vehicle_release), com o usuário logado e o motivo.
--
-- REGRAS (recusa com mensagem para o usuário):
-- - motivo obrigatório (mínimo 10 caracteres);
-- - NF precisa existir na foto atual, estar na Gold e em
--   WAITING_CRM com 0 pedido no CRM. Como WAITING_CRM só aparece
--   depois de prazo e BASE do Financeiro passarem, o app só deixa
--   liberar à mão quem cumpriu as regras do Financeiro;
-- - uma liberação ativa por NF.
--
-- EFEITO (transação única):
-- - linha em bronze_vehicle_release_manual_release;
-- - foto atual vira RELEASED / APP na hora (a próxima execução da
--   sync mantém, porque lê a tabela de liberações manuais);
-- - evento MANUAL_RELEASE no audit_history.
--
-- Usa o mesmo GET_LOCK da sync (espera até 10 s) para não gravar
-- no meio de uma execução.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_register_vehicle_release_manual;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_register_vehicle_release_manual(
    IN p_chassis_serial_number VARCHAR(17),
    IN p_invoice_number VARCHAR(9),
    IN p_issuance_date DATE,
    IN p_plant_code VARCHAR(10),
    IN p_released_by VARCHAR(150),
    IN p_release_reason VARCHAR(500)
)
BEGIN

    DECLARE c_lock_name VARCHAR(64) DEFAULT 'bp_datalake.vehicle_release_sync';
    DECLARE v_lock_acquired INT DEFAULT 0;
    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_reason VARCHAR(500) DEFAULT NULL;
    DECLARE v_status VARCHAR(30) DEFAULT NULL;
    DECLARE v_in_gold CHAR(3) DEFAULT NULL;
    DECLARE v_crm_match_count INT DEFAULT NULL;

    -- Qualquer erro: desfaz, solta o lock e devolve o erro ao app.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF v_lock_acquired = 1 THEN
            DO RELEASE_LOCK(c_lock_name);
        END IF;
        RESIGNAL;
    END;

    SET v_reason = NULLIF(TRIM(p_release_reason), '');

    IF NULLIF(TRIM(p_released_by), '') IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Usuário obrigatório para registrar a liberação.';
    END IF;

    IF v_reason IS NULL OR CHAR_LENGTH(v_reason) < 10 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Informe o motivo da liberação (mínimo 10 caracteres).';
    END IF;

    SET v_lock_acquired = COALESCE(GET_LOCK(c_lock_name, 10), 0);
    IF v_lock_acquired <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A validação da Liberação está rodando agora. Tente de novo em alguns minutos.';
    END IF;

    START TRANSACTION;

    SELECT release_status, in_gold, crm_match_count
    INTO v_status, v_in_gold, v_crm_match_count
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

    IF v_in_gold <> 'YES' OR v_status <> 'WAITING_CRM' OR v_crm_match_count <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Só NF em "Aguardando CRM" sem pedido no CRM pode ser liberada pelo app.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM bp_datalake.bronze_vehicle_release_manual_release
        WHERE chassis_serial_number = p_chassis_serial_number
          AND invoice_number = p_invoice_number
          AND issuance_date = p_issuance_date
          AND plant_code = p_plant_code
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Esta NF já tem uma liberação registrada no app.';
    END IF;

    INSERT INTO bp_datalake.bronze_vehicle_release_manual_release (
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        released_by, released_at, release_reason
    )
    VALUES (
        p_chassis_serial_number, p_invoice_number, p_issuance_date, p_plant_code,
        TRIM(p_released_by), v_now, v_reason
    );

    UPDATE bp_datalake.bronze_vehicle_release
    SET
        status_since = v_now,
        release_status = 'RELEASED',
        released_source = 'APP',
        release_status_reason = LEFT(CONCAT('Liberado no app por ', TRIM(p_released_by), ': ', v_reason), 500)
    WHERE chassis_serial_number = p_chassis_serial_number
      AND invoice_number = p_invoice_number
      AND issuance_date = p_issuance_date
      AND plant_code = p_plant_code;

    -- run_id 0 = ação de pessoa fora de uma execução da sync.
    INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
        run_id, triggered_by,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        change_type, old_status, new_status, status_reason, changed_at
    )
    VALUES (
        0, TRIM(p_released_by),
        p_chassis_serial_number, p_invoice_number, p_issuance_date, p_plant_code,
        'MANUAL_RELEASE', v_status, 'RELEASED', v_reason, v_now
    );

    COMMIT;

    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

END$$

DELIMITER ;
