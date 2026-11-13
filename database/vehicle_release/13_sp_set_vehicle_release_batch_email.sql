-- ============================================================
-- PROCEDURE: bp_datalake.sp_set_vehicle_release_batch_email
-- CAMADA: Bronze
--
-- OBJETIVO:
-- Gravar o resultado do e-mail de um lote de liberação (13/11/2026):
-- SENT (com destinatários e assunto) ou ERROR (com a mensagem).
--
-- QUEM CHAMA: o app, logo depois de tentar enviar o e-mail do lote
-- criado por sp_register_vehicle_release_batch.
--
-- REGRAS:
-- - status SENT ou ERROR;
-- - só muda lote ainda PENDING (o resultado é gravado uma vez só).
-- ============================================================

DROP PROCEDURE IF EXISTS bp_datalake.sp_set_vehicle_release_batch_email;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_set_vehicle_release_batch_email(
    IN p_batch_id BIGINT,
    IN p_email_status VARCHAR(10),
    IN p_email_recipients VARCHAR(1000),
    IN p_email_subject VARCHAR(300),
    IN p_email_error VARCHAR(1000)
)
BEGIN

    IF p_email_status NOT IN ('SENT', 'ERROR') OR p_email_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Resultado do e-mail inválido (SENT ou ERROR).';
    END IF;

    UPDATE bp_datalake.bronze_vehicle_release_batch
    SET
        email_status = p_email_status,
        email_recipients = LEFT(p_email_recipients, 1000),
        email_subject = LEFT(p_email_subject, 300),
        email_error = LEFT(p_email_error, 1000),
        email_finished_at = NOW()
    WHERE batch_id = p_batch_id
      AND email_status = 'PENDING';

    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lote não encontrado ou e-mail já registrado.';
    END IF;

END$$

DELIMITER ;
