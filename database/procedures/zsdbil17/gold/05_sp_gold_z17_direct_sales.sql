/*
===============================================================================
ZSDBIL17 - GOLD
05 - DIRECT SALES
===============================================================================

OBJETIVO
--------
Enriquecer a Gold com informações provenientes da base de Direct Sales.

CAMPOS PREENCHIDOS
------------------
- order_no
- order_car_no
- order_status

CHAVE DE RELACIONAMENTO
-----------------------
Gold:
    chassis_serial_number
    invoice_number

Direct Sales:
    vin
    invoice_no

Relacionamento:
    chassis_serial_number = vin
    invoice_number        = invoice_no

FILTRO DE NEGÓCIO
-----------------
Não são considerados registros das divisions:

    00
    B1
    B2

A rotina considera somente faturamentos do ano corrente
até a data atual.

TRATAMENTO DE DUPLICIDADE
-------------------------
1 match:
    utiliza diretamente.

Mais de 1 match:
    - extrai a data existente no order_no;
    - considera somente ordens criadas até invoice_date;
    - escolhe a ordem válida mais recente.

Exemplo:

    DO-BR-20260306-006
          20260306

IMPORTANTE
----------
issuance_date não participa da chave de relacionamento.

A chave utilizada é:

    chassis_serial_number + invoice_number

===============================================================================
*/


DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_direct_sales;

DELIMITER $$


CREATE PROCEDURE bp_datalake.sp_gold_z17_direct_sales()
BEGIN

    /*
    ===========================================================================
    1. VARIÁVEIS
    ===========================================================================
    */

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_matched_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;
    DECLARE v_unmatched_rows BIGINT DEFAULT 0;

    DECLARE v_match_unique BIGINT DEFAULT 0;
    DECLARE v_match_duplicate BIGINT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ===========================================================================
    2. TRATAMENTO DE ERRO
    ===========================================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        SET v_finished_at = NOW(6);


        INSERT INTO bp_datalake.etl_execution_log (
            procedure_name,
            source_table,
            target_table,
            execution_status,
            executed_by,
            started_at,
            finished_at,
            source_rows,
            selected_rows,
            inserted_rows,
            updated_rows,
            rejected_rows,
            error_code,
            error_message,
            execution_duration_seconds
        )
        VALUES (
            'sp_gold_z17_direct_sales',
            'dwd_sal_slm_direct_sale_order_details_wide',
            'gold_zsdbil17_faturamento_v2',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_matched_rows,
            0,
            v_updated_rows,
            v_unmatched_rows,
            v_error_code,
            v_error_message,
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000
        );

        COMMIT;

        RESIGNAL;

    END;


    /*
    ===========================================================================
    3. INÍCIO
    ===========================================================================
    */

    SET v_started_at = NOW(6);

    START TRANSACTION;


    /*
    ===========================================================================
    4. LIMPEZA DAS TEMPORÁRIAS
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_ds_gold_eligible;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_count;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_resolved;


    /*
    ===========================================================================
    5. GOLD ELEGÍVEL
    ===========================================================================

    Regras:

    - division diferente de 00, B1 e B2;
    - faturamentos do ano corrente;
    - somente datas até hoje.
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_gold_eligible AS

    SELECT
        g.id_bronze AS id,
        g.chassis_serial_number,
        g.invoice_number,
        g.issuance_date,
        g.division

    FROM bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    WHERE g.division NOT IN ('00', 'B1', 'B2')

      AND g.issuance_date >= MAKEDATE(
            YEAR(CURDATE()),
            1
          )

      AND g.issuance_date < CURDATE() + INTERVAL 1 DAY;


    ALTER TABLE tmp_ds_gold_eligible

        ADD PRIMARY KEY (id),

        ADD INDEX idx_tmp_ds_gold_chassis_invoice (
            chassis_serial_number,
            invoice_number
        );


    /*
    Quantidade de registros elegíveis.
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM tmp_ds_gold_eligible;

    /*
    ===============================================================================
    5.1 LIMPEZA DO ENRIQUECIMENTO ANTERIOR
    ===============================================================================

    Remove valores de Direct Sales previamente gravados para o mesmo
    escopo que será recalculado nesta execução.

    Isso evita manter dados residuais quando um registro da Gold
    deixa de possuir correspondência válida na base de Direct Sales.
    ===============================================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    INNER JOIN tmp_ds_gold_eligible AS e
        ON e.id = g.id_bronze

    SET
        g.order_no = NULL,
        g.order_car_no = NULL,
        g.order_status = NULL

    WHERE
        g.order_no IS NOT NULL 
        OR g.order_car_no IS NOT NULL
        OR g.order_status IS NOT NULL;

    /*
    ===========================================================================
    6. MATCH COM DIRECT SALES
    ===========================================================================

    Chave:

        gold.chassis_serial_number = direct_sales.vin
        gold.invoice_number        = direct_sales.invoice_no

    issuance_date NÃO participa da chave.
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_base AS

    SELECT
        g.id AS gold_id,

        d.invoice_date,
        d.order_no,
        d.order_car_no,
        d.order_status

    FROM tmp_ds_gold_eligible AS g

    INNER JOIN bp_datalake.dwd_sal_slm_direct_sale_order_details_wide AS d

        ON g.chassis_serial_number = d.vin
       AND g.invoice_number = d.invoice_no

    WHERE d.invoice_date >= MAKEDATE(
            YEAR(CURDATE()),
            1
          )

      AND d.invoice_date < CURDATE() + INTERVAL 1 DAY;


    ALTER TABLE tmp_ds_match_base
        ADD INDEX idx_tmp_ds_match_gold_id (gold_id);


    /*
    ===========================================================================
    7. QUANTIDADE DE MATCHES POR REGISTRO
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_count AS

    SELECT
        gold_id,
        COUNT(*) AS match_count

    FROM tmp_ds_match_base

    GROUP BY gold_id;


    ALTER TABLE tmp_ds_match_count
        ADD PRIMARY KEY (gold_id);


    /*
    ===========================================================================
    8. MÉTRICAS DE MATCH
    ===========================================================================
    */

    SELECT COUNT(*)
    INTO v_match_unique

    FROM tmp_ds_match_count

    WHERE match_count = 1;


    SELECT COUNT(*)
    INTO v_match_duplicate

    FROM tmp_ds_match_count

    WHERE match_count > 1;


    /*
    ===========================================================================
    9. RESULTADO RESOLVIDO
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_resolved (

        gold_id BIGINT NOT NULL,

        order_no VARCHAR(100) NULL,
        order_car_no VARCHAR(100) NULL,
        order_status VARCHAR(100) NULL,

        PRIMARY KEY (gold_id)

    );


    /*
    ---------------------------------------------------------------------------
    9.1 MATCH ÚNICO
    ---------------------------------------------------------------------------
    */

    INSERT INTO tmp_ds_match_resolved (
        gold_id,
        order_no,
        order_car_no,
        order_status
    )

    SELECT
        m.gold_id,
        m.order_no,
        m.order_car_no,
        m.order_status

    FROM tmp_ds_match_base AS m

    INNER JOIN tmp_ds_match_count AS c
        ON m.gold_id = c.gold_id

    WHERE c.match_count = 1;


    /*
    ---------------------------------------------------------------------------
    9.2 MATCH DUPLICADO
    ---------------------------------------------------------------------------

    A data da ordem é extraída do order_no:

        DO-BR-YYYYMMDD-XXX

    São consideradas somente ordens criadas até invoice_date.

    Depois:

        ordem mais recente
        ↓
        maior order_no como desempate determinístico
    ---------------------------------------------------------------------------
    */

    INSERT INTO tmp_ds_match_resolved (
        gold_id,
        order_no,
        order_car_no,
        order_status
    )

    SELECT
        ranked.gold_id,
        ranked.order_no,
        ranked.order_car_no,
        ranked.order_status

    FROM (

        SELECT
            m.gold_id,
            m.order_no,
            m.order_car_no,
            m.order_status,

            ROW_NUMBER() OVER (

                PARTITION BY m.gold_id

                ORDER BY

                    STR_TO_DATE(
                        SUBSTRING(m.order_no, 7, 8),
                        '%Y%m%d'
                    ) DESC,

                    m.order_no DESC

            ) AS rn

        FROM tmp_ds_match_base AS m

        INNER JOIN tmp_ds_match_count AS c
            ON m.gold_id = c.gold_id

        WHERE c.match_count > 1

          AND STR_TO_DATE(
                SUBSTRING(m.order_no, 7, 8),
                '%Y%m%d'
              ) <= m.invoice_date

    ) AS ranked

    WHERE ranked.rn = 1;


    /*
    ===========================================================================
    10. MÉTRICAS FINAIS DE MATCH
    ===========================================================================

    matched_rows:
        quantidade real de registros da Gold que receberam
        uma ordem final resolvida.

    unmatched_rows:
        registros elegíveis sem ordem resolvida.
    ===========================================================================
    */

    SELECT COUNT(*)
    INTO v_matched_rows

    FROM tmp_ds_match_resolved;


    SET v_unmatched_rows =
        v_source_rows - v_matched_rows;


    /*
    ===========================================================================
    11. ATUALIZAÇÃO DA GOLD
    ===========================================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento_v2 AS g

    INNER JOIN tmp_ds_match_resolved AS r
        ON g.id_bronze = r.gold_id

    SET
        g.order_no = r.order_no,
        g.order_car_no = r.order_car_no,
        g.order_status = r.order_status;


    /*
    updated_rows é uma métrica técnica.

    A métrica de negócio principal é matched_rows.
    */

    SET v_updated_rows = ROW_COUNT();


    /*
    ===========================================================================
    12. FINALIZA EXECUÇÃO
    ===========================================================================
    */

    SET v_finished_at = NOW(6);


    /*
    ===========================================================================
    13. LOG DE SUCESSO
    ===========================================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        finished_at,
        source_rows,
        selected_rows,
        inserted_rows,
        updated_rows,
        rejected_rows,
        error_code,
        error_message,
        execution_duration_seconds
    )

    VALUES (
        'sp_gold_z17_direct_sales',
        'dwd_sal_slm_direct_sale_order_details_wide',
        'gold_zsdbil17_faturamento_v2',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_matched_rows,
        0,
        v_updated_rows,
        v_unmatched_rows,
        NULL,
        NULL,

        TIMESTAMPDIFF(
            MICROSECOND,
            v_started_at,
            v_finished_at
        ) / 1000000

    );


    /*
    ===========================================================================
    14. CONFIRMA TRANSAÇÃO
    ===========================================================================
    */

    COMMIT;


    /*
    ===========================================================================
    15. LIMPEZA DAS TEMPORÁRIAS
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_resolved;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_count;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_gold_eligible;


    /*
    ===========================================================================
    16. RETORNO
    ===========================================================================
    */

    SELECT

        'SUCCESS' AS execution_status,

        v_source_rows AS eligible_rows,

        v_matched_rows AS matched_rows,

        v_match_unique AS unique_matches,

        v_match_duplicate AS duplicate_matches,

        v_unmatched_rows AS unmatched_rows,

        /*
        Apenas métrica técnica.
        */
        v_updated_rows AS updated_rows,

        /*
        Validação simples das métricas.
        */
        (
            v_matched_rows
            + v_unmatched_rows
        ) AS accounted_rows,

        ROUND(
            TIMESTAMPDIFF(
                MICROSECOND,
                v_started_at,
                v_finished_at
            ) / 1000000,
            2
        ) AS execution_duration_seconds,

        v_started_at AS started_at,

        v_finished_at AS finished_at;

END$$

DELIMITER ;
