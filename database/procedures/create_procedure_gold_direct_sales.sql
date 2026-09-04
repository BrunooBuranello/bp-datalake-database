/*
===============================================================================
PROCEDURE: sp_enrich_gold_direct_sales
===============================================================================

OBJETIVO
--------
Enriquecer a tabela gold_zsdbil17_faturamento com informações de pedido
provenientes da dwd_sal_slm_direct_sale_order_details_wide.

CAMPOS PREENCHIDOS
------------------
- order_no
- order_car_no
- order_status

REGRA PRINCIPAL
---------------
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

A rotina trabalha com faturamentos do ano corrente até a data atual.

TRATAMENTO DE DUPLICIDADE
-------------------------
Quando chassis + invoice encontra somente uma ordem:
    - utiliza a ordem diretamente.

Quando encontra mais de uma ordem:
    - extrai a data existente no order_no;
    - considera somente ordens criadas até a invoice_date;
    - escolhe a ordem válida mais recente.

Exemplo:
    DO-BR-20260306-006
          20260306

VALIDAÇÕES REALIZADAS
---------------------
Foi validado que:

- chassis + invoice é a chave principal de relacionamento;
- existem casos pontuais com mais de uma ordem;
- duplicidades precisam de regra determinística;
- cada registro da Gold recebe no máximo uma ordem;
- invoice_date e issuance_date podem apresentar pequena divergência.

Por esse motivo, issuance_date não participa da chave principal.

AUDITORIA
---------
Cada execução é registrada em etl_execution_log.

São registrados:
- quantidade elegível;
- quantidade com match;
- quantidade atualizada;
- quantidade sem match;
- duração;
- usuário executor;
- sucesso ou erro.

===============================================================================
*/


DROP PROCEDURE IF EXISTS sp_enrich_gold_direct_sales;

DELIMITER $$

CREATE PROCEDURE sp_enrich_gold_direct_sales()
BEGIN

    /*
    ===========================================================================
    1. VARIÁVEIS DE CONTROLE
    ===========================================================================
    */

    DECLARE v_started_at DATETIME(6);
    DECLARE v_finished_at DATETIME(6);

    DECLARE v_source_rows INT DEFAULT 0;
    DECLARE v_selected_rows INT DEFAULT 0;
    DECLARE v_updated_rows INT DEFAULT 0;
    DECLARE v_rejected_rows INT DEFAULT 0;

    DECLARE v_match_unique INT DEFAULT 0;
    DECLARE v_match_duplicate INT DEFAULT 0;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ===========================================================================
    2. TRATAMENTO DE ERRO

    Em caso de erro:
    - captura código e mensagem;
    - desfaz alterações;
    - registra a falha no log;
    - devolve o erro para quem chamou a procedure.
    ===========================================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        SET v_finished_at = NOW(6);

        INSERT INTO etl_execution_log (
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
            'sp_enrich_gold_direct_sales',
            'dwd_sal_slm_direct_sale_order_details_wide',
            'gold_zsdbil17_faturamento',
            'ERROR',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,
            v_source_rows,
            v_selected_rows,
            0,
            v_updated_rows,
            v_rejected_rows,
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
    3. INÍCIO DA EXECUÇÃO
    ===========================================================================
    */

    SET v_started_at = NOW(6);

    START TRANSACTION;


    /*
    ===========================================================================
    4. LIMPEZA DAS TABELAS TEMPORÁRIAS

    Garante que uma nova chamada da procedure não reutilize temporárias
    existentes na mesma conexão.
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_ds_gold_elegivel;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_count;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_resolvido;


    /*
    ===========================================================================
    5. GOLD ELEGÍVEL

    Seleciona somente:
    - divisions diferentes de 00, B1 e B2;
    - faturamentos do ano corrente;
    - datas até o dia atual.
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_gold_elegivel AS

    SELECT
        id,
        chassis_serial_number,
        invoice_number,
        issuance_date,
        division

    FROM gold_zsdbil17_faturamento

    WHERE division NOT IN ('00', 'B1', 'B2')

      AND issuance_date >= MAKEDATE(YEAR(CURDATE()), 1)

      AND issuance_date < CURDATE() + INTERVAL 1 DAY;


    /*
    Índices nas temporárias ajudam os joins das próximas etapas.
    */

    ALTER TABLE tmp_ds_gold_elegivel
        ADD PRIMARY KEY (id),
        ADD INDEX idx_tmp_gold_chassis_invoice (
            chassis_serial_number,
            invoice_number
        );


    /*
    Quantidade total de registros considerados pela procedure.
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM tmp_ds_gold_elegivel;


    /*
    ===========================================================================
    6. MATCH BASE COM DIRECT SALES

    Chave:

        Gold.chassis_serial_number = Direct Sales.vin
        Gold.invoice_number        = Direct Sales.invoice_no

    issuance_date não entra no relacionamento.
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_base AS

    SELECT
        g.id AS gold_id,

        d.invoice_date,
        d.order_no,
        d.order_car_no,
        d.order_status

    FROM tmp_ds_gold_elegivel g

    INNER JOIN dwd_sal_slm_direct_sale_order_details_wide d
        ON g.chassis_serial_number = d.vin
       AND g.invoice_number = d.invoice_no

    WHERE d.invoice_date >= MAKEDATE(YEAR(CURDATE()), 1)

      AND d.invoice_date < CURDATE() + INTERVAL 1 DAY;


    ALTER TABLE tmp_ds_match_base
        ADD INDEX idx_tmp_match_gold_id (gold_id);


    /*
    ===========================================================================
    7. CONTA QUANTOS MATCHES EXISTEM POR REGISTRO DA GOLD

    Essa etapa permite separar:

        1 match  -> caso simples
        >1 match -> precisa desempate
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_count AS

    SELECT
        gold_id,
        COUNT(*) AS qtd_match

    FROM tmp_ds_match_base

    GROUP BY gold_id;


    ALTER TABLE tmp_ds_match_count
        ADD PRIMARY KEY (gold_id);


    /*
    Métrica: quantidade de registros com match único.
    */

    SELECT COUNT(*)
    INTO v_match_unique
    FROM tmp_ds_match_count
    WHERE qtd_match = 1;


    /*
    Métrica: quantidade de registros com mais de um match.
    */

    SELECT COUNT(*)
    INTO v_match_duplicate
    FROM tmp_ds_match_count
    WHERE qtd_match > 1;


    /*
    ===========================================================================
    8. RESULTADO RESOLVIDO

    Primeiro entram todos os matches únicos.

    Depois entram os duplicados já tratados pela regra da data.
    ===========================================================================
    */

    CREATE TEMPORARY TABLE tmp_ds_match_resolvido (

        gold_id BIGINT NOT NULL,

        order_no VARCHAR(100) NULL,
        order_car_no VARCHAR(100) NULL,
        order_status VARCHAR(100) NULL,

        PRIMARY KEY (gold_id)
    );


    /*
    ---------------------------------------------------------------------------
    8.1 MATCHES ÚNICOS

    Não existe necessidade de ranking.
    ---------------------------------------------------------------------------
    */

    INSERT INTO tmp_ds_match_resolvido (
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

    FROM tmp_ds_match_base m

    INNER JOIN tmp_ds_match_count c
        ON m.gold_id = c.gold_id

    WHERE c.qtd_match = 1;


    /*
    ---------------------------------------------------------------------------
    8.2 MATCHES DUPLICADOS

    A data da ordem é extraída de:

        DO-BR-YYYYMMDD-XXX

    Apenas ordens criadas até invoice_date são consideradas.

    ROW_NUMBER escolhe a ordem válida mais recente.
    ---------------------------------------------------------------------------
    */

    INSERT INTO tmp_ds_match_resolvido (
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

        FROM tmp_ds_match_base m

        INNER JOIN tmp_ds_match_count c
            ON m.gold_id = c.gold_id

        WHERE c.qtd_match > 1

          AND STR_TO_DATE(
                SUBSTRING(m.order_no, 7, 8),
                '%Y%m%d'
              ) <= m.invoice_date

    ) ranked

    WHERE ranked.rn = 1;


    /*
    ===========================================================================
    9. MÉTRICAS DE MATCH

    selected_rows:
        registros que conseguiram uma ordem final válida.

    rejected_rows:
        registros elegíveis que ficaram sem match.
    ===========================================================================
    */

    SELECT COUNT(*)
    INTO v_selected_rows
    FROM tmp_ds_match_resolvido;


    SET v_rejected_rows =
        v_source_rows - v_selected_rows;


    /*
    ===========================================================================
    10. ATUALIZAÇÃO DA GOLD

    Somente registros com match resolvido são atualizados.

    Registros sem match permanecem NULL.
    ===========================================================================
    */

    UPDATE gold_zsdbil17_faturamento g

    INNER JOIN tmp_ds_match_resolvido r
        ON g.id = r.gold_id

    SET
        g.order_no = r.order_no,
        g.order_car_no = r.order_car_no,
        g.order_status = r.order_status;


    /*
    ROW_COUNT informa quantas linhas realmente sofreram alteração.

    Em execuções futuras, selected_rows pode continuar alto enquanto
    updated_rows pode ser menor caso os valores já estejam atualizados.
    */

    SET v_updated_rows = ROW_COUNT();


    /*
    ===========================================================================
    11. FINALIZA EXECUÇÃO
    ===========================================================================
    */

    SET v_finished_at = NOW(6);


    /*
    ===========================================================================
    12. REGISTRA SUCESSO NO LOG
    ===========================================================================
    */

    INSERT INTO etl_execution_log (
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
        'sp_enrich_gold_direct_sales',
        'dwd_sal_slm_direct_sale_order_details_wide',
        'gold_zsdbil17_faturamento',
        'SUCCESS',
        CURRENT_USER(),
        v_started_at,
        v_finished_at,
        v_source_rows,
        v_selected_rows,
        0,
        v_updated_rows,
        v_rejected_rows,
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
    13. CONFIRMA TRANSAÇÃO
    ===========================================================================
    */

    COMMIT;


    /*
    ===========================================================================
    14. REMOVE TEMPORÁRIAS
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_resolvido;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_count;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_match_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_ds_gold_elegivel;


    /*
    ===========================================================================
    15. RETORNO PARA CONSULTA MANUAL

    Mostra um resumo simples ao executar CALL pelo DBeaver.
    ===========================================================================
    */

    SELECT
        'SUCCESS' AS status,

        v_source_rows AS eligible_rows,

        v_selected_rows AS matched_rows,

        v_match_unique AS unique_matches,

        v_match_duplicate AS duplicate_matches,

        v_rejected_rows AS unmatched_rows,

        v_updated_rows AS updated_rows,

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
