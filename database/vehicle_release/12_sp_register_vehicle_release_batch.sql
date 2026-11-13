-- ============================================================
-- PROCEDURE: bp_datalake.sp_register_vehicle_release_batch
-- CAMADA: Bronze
--
-- OBJETIVO:
-- "Registrar liberação" em lote (13/11/2026): pega TODAS as NFs
-- em READY_TO_RELEASE (na Gold), grava o lote e a foto de cada NF
-- (BASE do Financeiro, prazo, CRM) e devolve o batch_id para o app
-- montar o e-mail com o Excel dos chassis.
--
-- QUEM CHAMA: botão "Registrar liberação" do app (permissão
-- execute_vehicle_release), com o modo e o usuário logado.
--
-- MODOS:
-- - TEST: só grava o lote. NENHUM status muda (o time ainda libera
--   offline; o e-mail vai só para quem clicou).
-- - PRODUCTION: além do lote, libera as NFs: linha ativa em
--   bronze_vehicle_release_manual_release (a próxima sync mantém
--   RELEASED / APP), foto atual RELEASED / APP e evento
--   BATCH_RELEASE no audit_history (run_id 0 = ação de pessoa).
--
-- FOTO DO FINANCEIRO (pedido do Bruno, 13/11/2026):
-- - lote: última carga SUCCESS da planilha de crédito (run, data/hora
--   do arquivo e fim da carga);
-- - NF: valor a pagar, valor recebido, vencimento e dt_carga da
--   linha da BASE (chassi + NF, a coluna chave da planilha).
--
-- REGRAS (recusa com mensagem para o usuário):
-- - modo TEST ou PRODUCTION; usuário obrigatório;
-- - pelo menos 1 NF pronta para liberar.
--
-- Usa o mesmo GET_LOCK da sync (espera até 10 s) para não gravar
-- no meio de uma execução.
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_register_vehicle_release_batch;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_register_vehicle_release_batch(
    IN p_batch_mode VARCHAR(10),
    IN p_requested_by VARCHAR(150),
    OUT p_batch_id BIGINT
)
BEGIN

    DECLARE c_lock_name VARCHAR(64) DEFAULT 'bp_datalake.vehicle_release_sync';
    DECLARE v_lock_acquired INT DEFAULT 0;
    DECLARE v_now DATETIME DEFAULT NOW();
    DECLARE v_user VARCHAR(150) DEFAULT NULL;
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_fin_run_id BIGINT DEFAULT NULL;
    DECLARE v_fin_file_modified_at DATETIME DEFAULT NULL;
    DECLARE v_fin_loaded_at DATETIME DEFAULT NULL;

    -- Qualquer erro: desfaz, solta o lock e devolve o erro ao app.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_vrb_ready;
        DROP TEMPORARY TABLE IF EXISTS tmp_vrb_finance;
        IF v_lock_acquired = 1 THEN
            DO RELEASE_LOCK(c_lock_name);
        END IF;
        RESIGNAL;
    END;

    SET p_batch_id = NULL;
    SET v_user = NULLIF(TRIM(p_requested_by), '');

    IF p_batch_mode NOT IN ('TEST', 'PRODUCTION') OR p_batch_mode IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Modo do lote inválido (TEST ou PRODUCTION).';
    END IF;

    IF v_user IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Usuário obrigatório para registrar a liberação.';
    END IF;

    SET v_lock_acquired = COALESCE(GET_LOCK(c_lock_name, 10), 0);
    IF v_lock_acquired <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A validação da Liberação está rodando agora. Tente de novo em alguns minutos.';
    END IF;

    -- NFs do lote: todas as prontas para liberar, na ordem da fila.
    DROP TEMPORARY TABLE IF EXISTS tmp_vrb_ready;
    CREATE TEMPORARY TABLE tmp_vrb_ready (
        chassis VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        issuance_date DATE NOT NULL,
        plant_code VARCHAR(10) NOT NULL,
        PRIMARY KEY (chassis, invoice_number, issuance_date, plant_code)
    );

    INSERT INTO tmp_vrb_ready
    SELECT chassis_serial_number, invoice_number, issuance_date, plant_code
    FROM bp_datalake.bronze_vehicle_release
    WHERE release_status = 'READY_TO_RELEASE'
      AND in_gold = 'YES';

    SELECT COUNT(*) INTO v_count FROM tmp_vrb_ready;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Nenhuma NF pronta para liberar agora.';
    END IF;

    -- Arquivo de crédito consumido: última carga que gravou a BASE.
    SELECT run_id, source_file_modified_at, finished_at
    INTO v_fin_run_id, v_fin_file_modified_at, v_fin_loaded_at
    FROM bp_datalake.bronze_finance_credit_load_run_audit_history
    WHERE run_status = 'SUCCESS'
    ORDER BY run_id DESC
    LIMIT 1;

    -- Foto da BASE por NF (chassi + NF; a coluna chave da planilha).
    -- MAX: a BASE tem poucas chaves repetidas; fica um valor por NF.
    DROP TEMPORARY TABLE IF EXISTS tmp_vrb_finance;
    CREATE TEMPORARY TABLE tmp_vrb_finance (
        chassis VARCHAR(17) NOT NULL,
        invoice_number VARCHAR(9) NOT NULL,
        invoice_amount VARCHAR(50) NULL,
        amount_received VARCHAR(50) NULL,
        due_date VARCHAR(50) NULL,
        loaded_at VARCHAR(30) NULL,
        PRIMARY KEY (chassis, invoice_number)
    );

    INSERT INTO tmp_vrb_finance
    SELECT
        r.chassis,
        r.invoice_number,
        LEFT(MAX(TRIM(f.invoice_amount)), 50),
        LEFT(MAX(TRIM(f.amount_received)), 50),
        LEFT(MAX(TRIM(f.due_date)), 50),
        LEFT(MAX(TRIM(f.dt_carga)), 30)
    FROM tmp_vrb_ready AS r
    JOIN bp_datalake.bronze_finance_credit_base AS f
        ON  f.chassis = r.chassis
        AND LPAD(TRIM(f.invoice_number), 9, '0') = r.invoice_number
    GROUP BY r.chassis, r.invoice_number;

    START TRANSACTION;

    INSERT INTO bp_datalake.bronze_vehicle_release_batch (
        batch_mode, requested_by, requested_at, nfs_count,
        finance_load_run_id, finance_file_modified_at, finance_loaded_at
    )
    VALUES (
        p_batch_mode, v_user, v_now, v_count,
        v_fin_run_id, v_fin_file_modified_at, v_fin_loaded_at
    );
    SET p_batch_id = LAST_INSERT_ID();

    INSERT INTO bp_datalake.bronze_vehicle_release_batch_item (
        batch_id,
        chassis_serial_number, invoice_number, issuance_date, plant_code,
        release_status, division, is_rental_company, model_simplified,
        total_amount, payment_term_days, crm_order_no, crm_order_sub_status,
        finance_invoice_amount, finance_amount_received, finance_due_date,
        finance_base_loaded_at
    )
    SELECT
        p_batch_id,
        v.chassis_serial_number, v.invoice_number, v.issuance_date, v.plant_code,
        v.release_status, v.division, v.is_rental_company, v.model_simplified,
        v.total_amount, v.payment_term_days, v.crm_order_no, v.crm_order_sub_status,
        f.invoice_amount, f.amount_received, f.due_date,
        f.loaded_at
    FROM tmp_vrb_ready AS r
    JOIN bp_datalake.bronze_vehicle_release AS v
        ON  v.chassis_serial_number = r.chassis
        AND v.invoice_number = r.invoice_number
        AND v.issuance_date = r.issuance_date
        AND v.plant_code = r.plant_code
    LEFT JOIN tmp_vrb_finance AS f
        ON  f.chassis = r.chassis
        AND f.invoice_number = r.invoice_number;

    IF p_batch_mode = 'PRODUCTION' THEN

        -- Mesma tabela da liberação offline: a sync lê e mantém RELEASED / APP.
        -- Linha desfeita antes (is_active = NO) volta a valer com o lote novo.
        INSERT INTO bp_datalake.bronze_vehicle_release_manual_release (
            chassis_serial_number, invoice_number, issuance_date, plant_code,
            released_by, released_at, release_reason
        )
        SELECT
            r.chassis, r.invoice_number, r.issuance_date, r.plant_code,
            v_user, v_now, CONCAT('Liberação em lote nº ', p_batch_id)
        FROM tmp_vrb_ready AS r
        ON DUPLICATE KEY UPDATE
            released_by = VALUES(released_by),
            released_at = VALUES(released_at),
            release_reason = VALUES(release_reason),
            is_active = 'YES',
            revoked_by = NULL,
            revoked_at = NULL,
            revoke_reason = NULL;

        INSERT INTO bp_datalake.bronze_vehicle_release_audit_history (
            run_id, triggered_by,
            chassis_serial_number, invoice_number, issuance_date, plant_code,
            change_type, old_status, new_status, status_reason, changed_at
        )
        SELECT
            0, v_user,
            r.chassis, r.invoice_number, r.issuance_date, r.plant_code,
            'BATCH_RELEASE', 'READY_TO_RELEASE', 'RELEASED',
            CONCAT('Liberação em lote nº ', p_batch_id), v_now
        FROM tmp_vrb_ready AS r;

        UPDATE bp_datalake.bronze_vehicle_release AS v
        JOIN tmp_vrb_ready AS r
            ON  v.chassis_serial_number = r.chassis
            AND v.invoice_number = r.invoice_number
            AND v.issuance_date = r.issuance_date
            AND v.plant_code = r.plant_code
        SET
            v.status_since = v_now,
            v.release_status = 'RELEASED',
            v.released_source = 'APP',
            v.release_status_reason = LEFT(CONCAT('Liberado no app em lote nº ', p_batch_id, ' por ', v_user), 500);

    END IF;

    COMMIT;

    DROP TEMPORARY TABLE IF EXISTS tmp_vrb_ready;
    DROP TEMPORARY TABLE IF EXISTS tmp_vrb_finance;
    DO RELEASE_LOCK(c_lock_name);
    SET v_lock_acquired = 0;

END$$

DELIMITER ;
