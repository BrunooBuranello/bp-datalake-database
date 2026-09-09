DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_normalize;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_z17_normalize()
BEGIN
    DECLARE v_rows_updated INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    /*
    ============================================================
    NORMALIZAÇÃO TÉCNICA
    ============================================================

    Regras:
    - remove espaços apenas nas extremidades
    - converte string vazia para NULL

    Não altera:
    - zeros à esquerda
    - conteúdo interno
    - códigos
    - formatação de negócio

    Colunas:
    - chassis_serial_number
    - invoice_number
    - descricao_do_produto
    - descricao_da_cor
    ============================================================
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements
    SET
        chassis_serial_number = NULLIF(TRIM(chassis_serial_number), ''),
        invoice_number = NULLIF(TRIM(invoice_number), ''),
        descricao_do_produto = NULLIF(TRIM(descricao_do_produto), ''),
        descricao_da_cor = NULLIF(TRIM(descricao_da_cor), '')
    WHERE
        (
            chassis_serial_number IS NOT NULL
            AND (
                chassis_serial_number <> TRIM(chassis_serial_number)
                OR TRIM(chassis_serial_number) = ''
            )
        )
        OR (
            invoice_number IS NOT NULL
            AND (
                invoice_number <> TRIM(invoice_number)
                OR TRIM(invoice_number) = ''
            )
        )
        OR (
            descricao_do_produto IS NOT NULL
            AND (
                descricao_do_produto <> TRIM(descricao_do_produto)
                OR TRIM(descricao_do_produto) = ''
            )
        )
        OR (
            descricao_da_cor IS NOT NULL
            AND (
                descricao_da_cor <> TRIM(descricao_da_cor)
                OR TRIM(descricao_da_cor) = ''
            )
        );

    SET v_rows_updated = ROW_COUNT();

    COMMIT;

    SELECT v_rows_updated AS rows_normalized;
END$$

DELIMITER ;
