/*
============================================================
ZSDBIL17 - SILVER - CLASSIFICACAO INCREMENTAL DE CFOP
============================================================

Objetivo:
Classificar cfop_car sem limitar a descoberta de novos
mapeamentos somente as datas recebidas na staging.

Em cada execucao normal a procedure processa:

1. Todas as linhas pertencentes as datas presentes na staging;
2. Todo o historico que ainda estiver com cfop_car = 'UNKNOWN'.

O segundo passo garante que, quando um CFOP anteriormente
desconhecido for cadastrado ou ativado na dim_cfop, o historico
seja reavaliado na proxima execucao do pipeline. As linhas que
passarem para YES poderao participar do load full refresh da
Gold, executado depois desta procedure.

Linhas UNKNOWN que continuarem sem correspondencia ativa na
dim_cfop permanecem UNKNOWN e serao verificadas novamente na
proxima execucao.

Importante:
- O reprocessamento historico e restrito aos UNKNOWN;
- Classificacoes YES e NO historicas nao sao recalculadas;
- O mapa considera somente dim_cfop.ativo = 1 e valores
  normalizados para YES ou NO.
============================================================
*/

DELIMITER $$

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_cfop$$

CREATE PROCEDURE bp_datalake.sp_silver_z17_cfop()
BEGIN

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_started_at DATETIME DEFAULT NOW();
    DECLARE v_finished_at DATETIME DEFAULT NULL;

    DECLARE v_column_exists INT DEFAULT 0;
    DECLARE v_column_created INT DEFAULT 0;

    DECLARE v_scope_dates INT DEFAULT 0;
    DECLARE v_scope_rows BIGINT DEFAULT 0;
    DECLARE v_updated_rows BIGINT DEFAULT 0;

    -- Quantidade historica de UNKNOWN revisada em toda execucao.
    DECLARE v_unknown_rechecked_rows BIGINT DEFAULT 0;

    -- UNKNOWN que encontrou uma classificacao nova (YES ou NO).
    DECLARE v_unknown_reclassified_rows BIGINT DEFAULT 0;

    DECLARE v_yes BIGINT DEFAULT 0;
    DECLARE v_no BIGINT DEFAULT 0;
    DECLARE v_unknown BIGINT DEFAULT 0;
    DECLARE v_classified_total BIGINT DEFAULT 0;

    DECLARE v_execution_mode VARCHAR(20) DEFAULT 'INCREMENTAL';

    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_mysql_errno INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ============================================================
    ERROR HANDLER
    ============================================================
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_sqlstate = RETURNED_SQLSTATE,
            v_mysql_errno = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;

        ROLLBACK;

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_scope_dates;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_map;

        SET v_finished_at = NOW();

        IF v_execution_id IS NOT NULL THEN

            UPDATE bp_datalake.etl_execution_log
            SET
                execution_status = 'ERROR',
                finished_at = v_finished_at,
                source_rows = v_scope_rows,
                selected_rows = v_scope_rows,
                inserted_rows = 0,
                updated_rows = v_updated_rows,
                rejected_rows = 0,

                error_code = CONCAT(
                    'MYSQL ',
                    v_mysql_errno,
                    ' | SQLSTATE ',
                    v_sqlstate
                ),

                error_message = v_error_message,

                audit_details = JSON_OBJECT(
                    'execution_mode', v_execution_mode,
                    'cfop_car_column_created', v_column_created,
                    'scope_dates', v_scope_dates,
                    'scope_rows', v_scope_rows,
                    'unknown_rechecked_rows', v_unknown_rechecked_rows,
                    'unknown_reclassified_rows', v_unknown_reclassified_rows,
                    'rows_changed', v_updated_rows
                ),

                execution_duration_seconds =
                    TIMESTAMPDIFF(
                        SECOND,
                        v_started_at,
                        v_finished_at
                    )

            WHERE id_execution = v_execution_id;

        END IF;

        RESIGNAL;

    END;


    /*
    ============================================================
    1. START LOG
    ============================================================
    */

    INSERT INTO bp_datalake.etl_execution_log (
        procedure_name,
        source_table,
        target_table,
        execution_status,
        executed_by,
        started_at,
        created_at
    )
    VALUES (
        'sp_silver_z17_cfop',
        'silver_zsdbil17_outbound_movements',
        'silver_zsdbil17_outbound_movements',
        'RUNNING',
        CURRENT_USER(),
        v_started_at,
        v_started_at
    );

    SET v_execution_id = LAST_INSERT_ID();


    /*
    ============================================================
    2. ENSURE CFOP_CAR COLUMN
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_column_exists

    FROM information_schema.columns

    WHERE table_schema = 'bp_datalake'
      AND table_name = 'silver_zsdbil17_outbound_movements'
      AND column_name = 'cfop_car';


    IF v_column_exists = 0 THEN

        ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
            ADD COLUMN cfop_car VARCHAR(10) NULL
            AFTER cfop;

        SET v_column_created = 1;
        SET v_execution_mode = 'FULL_INIT';

    END IF;


    /*
    ============================================================
    3. BUILD CFOP MAP
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_map;

    CREATE TEMPORARY TABLE tmp_z17_cfop_map AS

    SELECT
        TRIM(d.cfop) AS cfop,
        MAX(UPPER(TRIM(d.cfop_car))) AS cfop_car

    FROM bp_datalake.dim_cfop AS d

    WHERE d.ativo = 1

      AND UPPER(TRIM(d.cfop_car))
          IN ('YES', 'NO')

      AND NULLIF(TRIM(d.cfop), '') IS NOT NULL

    GROUP BY
        TRIM(d.cfop);


    ALTER TABLE tmp_z17_cfop_map
        ADD PRIMARY KEY (cfop);


    /*
    ============================================================
    4. FULL INIT
    ============================================================

    Só ocorre quando cfop_car acabou de ser criada.

    Nesse cenário precisamos classificar toda a Silver,
    caso contrário o histórico ficaria NULL.
    ============================================================
    */

    IF v_column_created = 1 THEN

        SELECT COUNT(*)
        INTO v_scope_rows
        FROM bp_datalake.silver_zsdbil17_outbound_movements;


        START TRANSACTION;


        UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

        LEFT JOIN tmp_z17_cfop_map AS m
            ON m.cfop = TRIM(s.cfop)

        SET
            s.cfop_car =
                COALESCE(
                    m.cfop_car,
                    'UNKNOWN'
                )

        WHERE NOT
        (
            s.cfop_car
            <=>
            COALESCE(
                m.cfop_car,
                'UNKNOWN'
            )
        );


        SET v_updated_rows = ROW_COUNT();


        SELECT
            COALESCE(SUM(cfop_car = 'YES'), 0),
            COALESCE(SUM(cfop_car = 'NO'), 0),
            COALESCE(SUM(cfop_car = 'UNKNOWN'), 0)

        INTO
            v_yes,
            v_no,
            v_unknown

        FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    5. NORMAL INCREMENTAL EXECUTION
    ============================================================
    */

    ELSE

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_scope_dates;

        CREATE TEMPORARY TABLE tmp_z17_cfop_scope_dates (
            issuance_date DATE NOT NULL,
            PRIMARY KEY (issuance_date)
        );


        INSERT INTO tmp_z17_cfop_scope_dates (
            issuance_date
        )

        SELECT DISTINCT
            issuance_date

        FROM bp_datalake.stg_zsdbil17_faturamento

        WHERE issuance_date IS NOT NULL;


        SELECT COUNT(*)
        INTO v_scope_dates
        FROM tmp_z17_cfop_scope_dates;


        IF v_scope_dates = 0 THEN

            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Silver Z17 CFOP: nenhuma issuance_date valida encontrada na staging.';

        END IF;


        SELECT COUNT(*)
        INTO v_scope_rows

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        INNER JOIN tmp_z17_cfop_scope_dates AS d
            ON d.issuance_date = s.issuance_date;


        START TRANSACTION;


        UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

        INNER JOIN tmp_z17_cfop_scope_dates AS d
            ON d.issuance_date = s.issuance_date

        LEFT JOIN tmp_z17_cfop_map AS m
            ON m.cfop = TRIM(s.cfop)

        SET
            s.cfop_car =
                COALESCE(
                    m.cfop_car,
                    'UNKNOWN'
                )

        WHERE NOT
        (
            s.cfop_car
            <=>
            COALESCE(
                m.cfop_car,
                'UNKNOWN'
            )
        );


        SET v_updated_rows = ROW_COUNT();


        /*
        ========================================================
        5.1. REVISA TODO O HISTORICO AINDA UNKNOWN
        ========================================================

        A carga incremental por data garante a classificacao das
        linhas recebidas na execucao atual, mas nao revisitaria um
        faturamento antigo caso seu CFOP fosse cadastrado depois
        na dim_cfop.

        Por isso, toda execucao tambem procura todos os UNKNOWN da
        Silver, independentemente da issuance_date. O INNER JOIN
        restringe o UPDATE aos CFOPs que agora possuem uma regra
        ativa e valida no mapa (YES ou NO).

        Registros ainda sem correspondencia nao sao alterados:
        continuam UNKNOWN e voltam a ser avaliados na proxima
        execucao do pipeline.

        Linhas da staging que permaneceram UNKNOWN tambem podem
        fazer parte desta contagem, mas somente serao atualizadas
        se houver correspondencia no mapa.
        ========================================================
        */

        SELECT COUNT(*)
        INTO v_unknown_rechecked_rows

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        WHERE UPPER(TRIM(s.cfop_car)) = 'UNKNOWN';


        UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

        INNER JOIN tmp_z17_cfop_map AS m
            ON m.cfop = TRIM(s.cfop)

        SET
            s.cfop_car = m.cfop_car

        WHERE UPPER(TRIM(s.cfop_car)) = 'UNKNOWN'

          AND NOT (
              s.cfop_car <=> m.cfop_car
          );


        SET v_unknown_reclassified_rows = ROW_COUNT();

        -- Consolida alteracoes da staging e do historico UNKNOWN.
        SET v_updated_rows =
              v_updated_rows
            + v_unknown_reclassified_rows;


        SELECT
            COALESCE(SUM(s.cfop_car = 'YES'), 0),
            COALESCE(SUM(s.cfop_car = 'NO'), 0),
            COALESCE(SUM(s.cfop_car = 'UNKNOWN'), 0)

        INTO
            v_yes,
            v_no,
            v_unknown

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        INNER JOIN tmp_z17_cfop_scope_dates AS d
            ON d.issuance_date = s.issuance_date;

    END IF;


    /*
    ============================================================
    6. VALIDATION
    ============================================================
    */

    SET v_classified_total =
          v_yes
        + v_no
        + v_unknown;


    IF v_classified_total <> v_scope_rows THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Silver Z17 CFOP: nem todas as linhas foram classificadas.';

    END IF;


    COMMIT;


    /*
    ============================================================
    7. CLEANUP
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_scope_dates;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_cfop_map;


    /*
    ============================================================
    8. SUCCESS LOG
    ============================================================
    */

    SET v_finished_at = NOW();


    UPDATE bp_datalake.etl_execution_log
    SET
        execution_status = 'SUCCESS',
        finished_at = v_finished_at,

        source_rows = v_scope_rows,
        selected_rows = v_scope_rows,
        inserted_rows = 0,
        updated_rows = v_updated_rows,
        rejected_rows = 0,

        error_code = NULL,
        error_message = NULL,

        audit_details = JSON_OBJECT(
            'execution_mode', v_execution_mode,
            'cfop_car_column_created', v_column_created,
            'scope_dates', v_scope_dates,
            'scope_rows', v_scope_rows,
            'unknown_rechecked_rows', v_unknown_rechecked_rows,
            'unknown_reclassified_rows', v_unknown_reclassified_rows,
            'rows_changed', v_updated_rows,
            'yes', v_yes,
            'no', v_no,
            'unknown', v_unknown,
            'classified_total', v_classified_total
        ),

        execution_duration_seconds =
            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            )

    WHERE id_execution = v_execution_id;


    /*
    ============================================================
    9. RETURN
    ============================================================
    */

    SELECT
        v_execution_id AS execution_id,
        'SUCCESS' AS execution_status,
        v_execution_mode AS execution_mode,

        v_column_created AS cfop_car_column_created,

        v_scope_dates AS scope_dates,
        v_scope_rows AS scope_rows,

        v_unknown_rechecked_rows AS unknown_rechecked_rows,
        v_unknown_reclassified_rows AS unknown_reclassified_rows,

        v_updated_rows AS rows_changed,

        v_yes AS yes,
        v_no AS no,
        v_unknown AS unknown,

        v_classified_total AS classified_total,

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        ) AS execution_duration_seconds;


END$$

DELIMITER ;
