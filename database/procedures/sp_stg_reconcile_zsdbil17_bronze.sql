/*
===============================================================================
PROCEDURE: sp_stg_reconcile_zsdbil17_bronze
===============================================================================

OBJETIVO
-------------------------------------------------------------------------------
Reconciliar o snapshot atual da ZSDBIL17 existente na staging
com o histórico persistido na Bronze.

ARQUITETURA
-------------------------------------------------------------------------------

    SAP
     |
     v
    stg_zsdbil17_faturamento
        Snapshot atual recebido do SAP
     |
     | reconciliation_hash
     v
    sp_stg_reconcile_zsdbil17_bronze
     |
     v
    bronze_zsdbil17_faturamento
        Histórico preservado


PRINCÍPIO DA BRONZE
-------------------------------------------------------------------------------
A Bronze representa histórico.

Por isso:

- registros nunca são deletados porque desapareceram do SAP;
- documentos que desaparecerem do snapshot podem virar MISSING;
- documentos novos são inseridos;
- documentos já conhecidos são confirmados;
- inconsistências estruturais bloqueiam a reconciliação.


CHAVE DE RECONCILIAÇÃO
-------------------------------------------------------------------------------

O reconciliation_hash representa um DOCUMENTO SAP:

    sap_document
    + company_code
    + plant_code
    + YEAR(issuance_date)

O hash utilizado é MD5 armazenado como BINARY(16).

IMPORTANTE:

O hash NÃO representa uma linha individual.

Exemplo:

    documento 809420
        300 itens
        300 linhas
        1 reconciliation_hash


VALIDAÇÃO DA QUANTIDADE
-------------------------------------------------------------------------------

Além da existência do hash, comparamos:

    COUNT(*) staging
        versus
    COUNT(*) Bronze

Se o mesmo documento possuir quantidade diferente de linhas,
a procedure NÃO tenta corrigir automaticamente.

Isso é tratado como anomalia de qualidade.

Motivo:

O documento SAP foi considerado imutável dentro dessa arquitetura.
Uma diferença de quantidade pode indicar:

- alteração inesperada na origem;
- erro de carga;
- duplicação;
- inconsistência histórica;
- mudança de regra do relatório.

Nesse caso a execução é interrompida para investigação.


STATUS
-------------------------------------------------------------------------------

ACTIVE
    Documento presente normalmente no snapshot.

CANCELLED
    Documento presente com indicação explícita de cancelamento.

MISSING
    Documento existia anteriormente na Bronze, mas deixou de
    existir no snapshot atual dentro de uma issuance_date
    efetivamente reconciliada.

UNKNOWN
    Registro histórico ainda não confirmado pela arquitetura
    nova.


ESCOPO DO MISSING
-------------------------------------------------------------------------------

Somente datas presentes na staging atual participam da busca
por documentos MISSING.

Exemplo:

Staging possui:

    2026-09-03
    2026-09-04

Somente registros Bronze dessas datas podem virar MISSING.

Isso impede que uma carga de poucos dias marque todo o histórico
antigo como desaparecido.


AUDITORIA
-------------------------------------------------------------------------------

Ao final da execução são registrados em etl_execution_log:

- quantidade de linhas recebidas;
- quantidade de documentos/hash;
- documentos existentes;
- documentos novos;
- documentos missing;
- divergências de quantidade;
- linhas inseridas;
- linhas ACTIVE;
- linhas CANCELLED;
- linhas MISSING;
- duração;
- erro, quando houver;
- detalhes adicionais em JSON.

===============================================================================
*/


DROP PROCEDURE IF EXISTS bp_datalake.sp_stg_reconcile_zsdbil17_bronze;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_stg_reconcile_zsdbil17_bronze()
BEGIN

    /*
    ===========================================================================
    1. CONTROLE GERAL DA EXECUÇÃO
    ===========================================================================
    */

    DECLARE v_started_at DATETIME DEFAULT NOW();
    DECLARE v_finished_at DATETIME;

    DECLARE v_execution_id BIGINT DEFAULT NULL;

    DECLARE v_error_code INT DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;


    /*
    ===========================================================================
    2. MÉTRICAS DE LINHAS
    ===========================================================================
    */

    DECLARE v_source_rows INT DEFAULT 0;

    DECLARE v_inserted_rows INT DEFAULT 0;
    DECLARE v_refreshed_rows INT DEFAULT 0;
    DECLARE v_refresh_deleted_rows INT DEFAULT 0;

    DECLARE v_active_updated INT DEFAULT 0;
    DECLARE v_cancelled_updated INT DEFAULT 0;
    DECLARE v_missing_updated INT DEFAULT 0;

    DECLARE v_hashes_generated INT DEFAULT 0;

    /*
    ===========================================================================
    3. MÉTRICAS DE DOCUMENTOS / HASHES
    ===========================================================================
    */

    -- Quantidade de issuance_date presentes no snapshot.
    DECLARE v_scope_dates INT DEFAULT 0;

    -- Quantidade de documentos distintos recebidos.
    DECLARE v_staging_hashes INT DEFAULT 0;

    -- Documentos que já existem na Bronze.
    DECLARE v_existing_hashes INT DEFAULT 0;

    -- Documentos completamente novos.
    DECLARE v_new_hashes INT DEFAULT 0;

    -- Documentos existentes substituídos pelo snapshot atual.
    DECLARE v_refreshed_hashes INT DEFAULT 0;

    -- Documentos que desapareceram do snapshot.
    DECLARE v_missing_hashes INT DEFAULT 0;

    -- Mesmo hash, porém quantidade diferente de itens.
    DECLARE v_count_mismatch_hashes INT DEFAULT 0;

    -- Documento contendo simultaneamente linhas ACTIVE e CANCELLED.
    DECLARE v_mixed_status_hashes INT DEFAULT 0;

    -- Linhas incapazes de gerar uma identidade confiável.
    DECLARE v_invalid_identity_rows INT DEFAULT 0;


    /*
    ===========================================================================
    4. SQL DINÂMICO
    ===========================================================================

    A ZSDBIL17 possui muitas colunas.

    Para evitar manter manualmente uma lista de mais de 100 campos,
    o INSERT Bronze é montado dinamicamente a partir das colunas que:

        existem na staging
        E
        existem na Bronze.

    Isso reduz manutenção quando novas colunas funcionais forem adicionadas.
    */

    DECLARE v_insert_columns LONGTEXT;
    DECLARE v_select_columns LONGTEXT;
    DECLARE v_sql LONGTEXT;

    DECLARE v_old_group_concat_max_len BIGINT;

    -- Controla se existe PREPARE aberto no momento de uma exceção.
    DECLARE v_stmt_prepared BOOLEAN DEFAULT FALSE;


    /*
    ===========================================================================
    5. TRATAMENTO GLOBAL DE ERRO
    ===========================================================================

    Qualquer erro:

        1. captura código e mensagem;
        2. executa ROLLBACK;
        3. limpa temporárias;
        4. restaura configurações da sessão;
        5. registra FAILED no log;
        6. devolve o erro original.

    O objetivo é impedir uma Bronze parcialmente reconciliada.
    */

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN

        GET DIAGNOSTICS CONDITION 1
            v_error_code = MYSQL_ERRNO,
            v_error_message = MESSAGE_TEXT;


        /*
        Desfaz as alterações realizadas na Bronze.
        */

        ROLLBACK;


        /*
        Se ocorreu erro entre PREPARE e DEALLOCATE,
        libera o statement.
        */

        IF v_stmt_prepared THEN

            DEALLOCATE PREPARE stmt;

        END IF;


        /*
        Limpeza das tabelas temporárias.
        */

        DROP TEMPORARY TABLE IF EXISTS tmp_z17_scope_dates;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_stg_summary;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_existing_summary;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_refresh_hashes;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_new_hashes;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_bronze_scope;
        DROP TEMPORARY TABLE IF EXISTS tmp_z17_missing_hashes;


        /*
        Restaura configuração original da sessão.
        */

        IF v_old_group_concat_max_len IS NOT NULL THEN

            SET SESSION group_concat_max_len =
                v_old_group_concat_max_len;

        END IF;


        SET @sql_reconcile_z17 = NULL;

        SET v_finished_at = NOW();


        /*
        -----------------------------------------------------------------------
        REGISTRO DE EXECUÇÃO COM ERRO
        -----------------------------------------------------------------------

        Mesmo falhas de qualidade são registradas.

        Isso é importante porque uma execução bloqueada também é informação
        operacional relevante.
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
            audit_details,
            execution_duration_seconds
        )

        VALUES (
            'sp_stg_reconcile_zsdbil17_bronze',
            'stg_zsdbil17_faturamento',
            'bronze_zsdbil17_faturamento',
            'FAILED',
            CURRENT_USER(),
            v_started_at,
            v_finished_at,

            v_source_rows,

            v_staging_hashes,

            v_inserted_rows,

            (
                v_active_updated
                + v_cancelled_updated
                + v_missing_updated
            ),

            (
                v_invalid_identity_rows
                + v_count_mismatch_hashes
                + v_mixed_status_hashes
            ),

            v_error_code,
            v_error_message,

            JSON_OBJECT(

                'scope_dates',
                v_scope_dates,

                'staging_hashes',
                v_staging_hashes,

                'existing_hashes',
                v_existing_hashes,

                'new_hashes',
                v_new_hashes,

                'refreshed_hashes',
                v_refreshed_hashes,

                'refreshed_rows',
                v_refreshed_rows,

                'missing_hashes',
                v_missing_hashes,

                'count_mismatch_hashes',
                v_count_mismatch_hashes,

                'mixed_status_hashes',
                v_mixed_status_hashes,

                'invalid_identity_rows',
                v_invalid_identity_rows,

                'active_rows_updated',
                v_active_updated,

                'cancelled_rows_updated',
                v_cancelled_updated,

                'missing_rows_updated',
                v_missing_updated
            ),

            TIMESTAMPDIFF(
                SECOND,
                v_started_at,
                v_finished_at
            )
        );


        /*
        Retorna o erro original para quem chamou a procedure.
        */

        RESIGNAL;

    END;


    /*
    ===========================================================================
    6. PREPARAR SESSÃO
    ===========================================================================
    */

    SET v_old_group_concat_max_len =
        @@SESSION.group_concat_max_len;


    /*
    Necessário porque a lista dinâmica de colunas da Z17 é grande.
    */

    SET SESSION group_concat_max_len = 1000000;


    /*
    ===========================================================================
    7. VALIDAR SE A STAGING POSSUI DADOS
    ===========================================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.stg_zsdbil17_faturamento;


    IF v_source_rows = 0 THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: staging vazia.';

    END IF;

    /*
    ===========================================================================
    8. GERAR reconciliation_hash AUSENTE NA STAGING
    ===========================================================================

    A staging é recarregada a cada snapshot.

    Por isso, o reconciliation_hash não pode depender de preenchimento manual.

    Toda linha sem hash recebe:

        sap_document
        + company_code
        + plant_code
        + YEAR(issuance_date)
    */

    UPDATE bp_datalake.stg_zsdbil17_faturamento
    SET reconciliation_hash = UNHEX(
        MD5(
            CONCAT_WS(
                '|',
                TRIM(sap_document),
                TRIM(company_code),
                TRIM(plant_code),
                YEAR(issuance_date)
            )
        )
    )
    WHERE reconciliation_hash IS NULL;

    SET v_hashes_generated = ROW_COUNT();
    /*
    ===========================================================================
    8.1 VALIDAR IDENTIDADE DOS DOCUMENTOS
    ===========================================================================

    Para participar da reconciliação precisamos conseguir identificar
    corretamente o documento.

    O reconciliation_hash depende de:

        sap_document
        company_code
        plant_code
        YEAR(issuance_date)

    Se qualquer parte necessária estiver ausente, a execução é bloqueada.

    Isso é intencional.

    É melhor parar a carga do que reconciliar dados com identidade duvidosa.
    */

    SELECT COUNT(*)
    INTO v_invalid_identity_rows

    FROM bp_datalake.stg_zsdbil17_faturamento

    WHERE reconciliation_hash IS NULL

       OR TRIM(
            COALESCE(
                sap_document,
                ''
            )
          ) = ''

       OR TRIM(
            COALESCE(
                company_code,
                ''
            )
          ) = ''

       OR TRIM(
            COALESCE(
                plant_code,
                ''
            )
          ) = ''

       OR issuance_date IS NULL;


    IF v_invalid_identity_rows > 0 THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: registros sem identidade valida.';

    END IF;


    /*
    Somente após as validações básicas abrimos a transação responsável
    pelas alterações na Bronze.
    */

    START TRANSACTION;


    /*
    ===========================================================================
    9. IDENTIFICAR DATAS RECEBIDAS NO SNAPSHOT
    ===========================================================================

    Esta tabela define o universo no qual podemos procurar documentos MISSING.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_scope_dates;


    CREATE TEMPORARY TABLE tmp_z17_scope_dates (

        issuance_date DATE NOT NULL,

        PRIMARY KEY (issuance_date)

    );


    INSERT INTO tmp_z17_scope_dates (
        issuance_date
    )

    SELECT DISTINCT
        issuance_date

    FROM bp_datalake.stg_zsdbil17_faturamento

    WHERE issuance_date IS NOT NULL;


    SELECT COUNT(*)
    INTO v_scope_dates
    FROM tmp_z17_scope_dates;


    IF v_scope_dates = 0 THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: nenhuma issuance_date valida.';

    END IF;


    /*
    ===========================================================================
    10. RESUMIR STAGING POR DOCUMENTO
    ===========================================================================

    Em vez de trabalhar com todas as linhas para descobrir existência,
    reduzimos o snapshot para uma linha por reconciliation_hash.

    Exemplo:

        documento 809420
        300 linhas staging

    vira:

        hash XYZ
        item_count = 300

    Esse é o núcleo da otimização da reconciliação.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_stg_summary;


    CREATE TEMPORARY TABLE tmp_z17_stg_summary (

        reconciliation_hash BINARY(16) NOT NULL,

        item_count INT NOT NULL,

        active_count INT NOT NULL,

        cancelled_count INT NOT NULL,

        PRIMARY KEY (reconciliation_hash)

    );


    INSERT INTO tmp_z17_stg_summary (
        reconciliation_hash,
        item_count,
        active_count,
        cancelled_count
    )

    SELECT

        reconciliation_hash,

        COUNT(*) AS item_count,


        /*
        chave_de_acesso diferente de 00
        é considerada situação normal/ACTIVE.
        */

        SUM(
            CASE
                WHEN TRIM(
                    COALESCE(
                        chave_de_acesso,
                        ''
                    )
                ) <> '00'
                    THEN 1
                ELSE 0
            END
        ) AS active_count,


        /*
        chave_de_acesso = 00
        representa cancelamento explícito conforme regra atual.
        */

        SUM(
            CASE
                WHEN TRIM(
                    COALESCE(
                        chave_de_acesso,
                        ''
                    )
                ) = '00'
                    THEN 1
                ELSE 0
            END
        ) AS cancelled_count


    FROM bp_datalake.stg_zsdbil17_faturamento

    GROUP BY
        reconciliation_hash;


    SELECT COUNT(*)
    INTO v_staging_hashes
    FROM tmp_z17_stg_summary;


    /*
    ===========================================================================
    11. VALIDAR DOCUMENTOS COM STATUS MISTO
    ===========================================================================

    Como o reconciliation_hash trabalha no nível do documento,
    precisamos evitar tomar uma decisão de documento quando:

        algumas linhas estão ACTIVE
        e
        outras linhas estão CANCELLED.

    Isso seria uma situação ambígua.

    Portanto, por segurança, a procedure não escolhe automaticamente
    um dos dois estados.
    */

    SELECT COUNT(*)
    INTO v_mixed_status_hashes

    FROM tmp_z17_stg_summary

    WHERE active_count > 0
      AND cancelled_count > 0;


    IF v_mixed_status_hashes > 0 THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: documento possui linhas ACTIVE e CANCELLED simultaneamente.';

    END IF;


    /*
    ===========================================================================
    12. LOCALIZAR DOCUMENTOS QUE JÁ EXISTEM NA BRONZE
    ===========================================================================

    Esta é a parte que substitui os antigos JOINs em campos TEXT.

    Antes:

        TRIM(sales_order_number)
        TRIM(sap_document)
        TRIM(chassis_serial_number)

    Agora:

        BINARY(16) = BINARY(16)

    reconciliation_hash possui índice nos dois lados.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_existing_summary;


    CREATE TEMPORARY TABLE tmp_z17_existing_summary (

        reconciliation_hash BINARY(16) NOT NULL,

        bronze_item_count INT NOT NULL,

        PRIMARY KEY (reconciliation_hash)

    );


    INSERT INTO tmp_z17_existing_summary (
        reconciliation_hash,
        bronze_item_count
    )

    SELECT

        s.reconciliation_hash,

        COUNT(b.id) AS bronze_item_count


    FROM tmp_z17_stg_summary s

    LEFT JOIN bp_datalake.bronze_zsdbil17_faturamento b

        ON b.reconciliation_hash =
           s.reconciliation_hash


    GROUP BY
        s.reconciliation_hash;


    /*
    Quantos documentos da staging já existiam.
    */

    SELECT COUNT(*)
    INTO v_existing_hashes

    FROM tmp_z17_existing_summary

    WHERE bronze_item_count > 0;


    /*
    Quantos documentos nunca existiram na Bronze.
    */

    SELECT COUNT(*)
    INTO v_new_hashes

    FROM tmp_z17_existing_summary

    WHERE bronze_item_count = 0;


    /*
    ===========================================================================
    13. VALIDAR QUANTIDADE DE ITENS
    ===========================================================================

    Documento existente:

        staging = 300
        bronze  = 300

        OK


    Documento existente:

        staging = 299
        bronze  = 300

        ERRO DE QUALIDADE


    Nós não tentamos corrigir esse cenário automaticamente.
    */

    SELECT COUNT(*)
    INTO v_count_mismatch_hashes

    FROM tmp_z17_existing_summary b

    INNER JOIN tmp_z17_stg_summary s

        ON s.reconciliation_hash =
           b.reconciliation_hash


    WHERE b.bronze_item_count > 0

      AND b.bronze_item_count <>
          s.item_count;


    IF v_count_mismatch_hashes > 0 THEN

        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: quantidade de itens diferente entre staging e Bronze.';

    END IF;


    /*
    ===========================================================================
    14. LISTAR DOCUMENTOS EXISTENTES PARA REFRESH
    ===========================================================================

    Mesmo hash + mesma quantidade:
        substitui o conjunto inteiro da Bronze pelo estado atual da staging.

    first_seen_at é preservado no nível do documento.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_refresh_hashes;

    CREATE TEMPORARY TABLE tmp_z17_refresh_hashes (
        reconciliation_hash BINARY(16) NOT NULL,
        first_seen_at DATETIME NULL,
        PRIMARY KEY (reconciliation_hash)
    );

    INSERT INTO tmp_z17_refresh_hashes (
        reconciliation_hash,
        first_seen_at
    )
    SELECT
        e.reconciliation_hash,
        MIN(b.first_seen_at)
    FROM tmp_z17_existing_summary e
    INNER JOIN tmp_z17_stg_summary s
        ON s.reconciliation_hash = e.reconciliation_hash
    INNER JOIN bp_datalake.bronze_zsdbil17_faturamento b
        ON b.reconciliation_hash = e.reconciliation_hash
    WHERE e.bronze_item_count > 0
      AND e.bronze_item_count = s.item_count
    GROUP BY e.reconciliation_hash;

    SELECT COUNT(*)
    INTO v_refreshed_hashes
    FROM tmp_z17_refresh_hashes;

    SELECT
        COALESCE(SUM(s.active_count), 0),
        COALESCE(SUM(s.cancelled_count), 0)
    INTO
        v_active_updated,
        v_cancelled_updated
    FROM tmp_z17_stg_summary s
    INNER JOIN tmp_z17_refresh_hashes r
        ON r.reconciliation_hash = s.reconciliation_hash;


    /*
    ===========================================================================
    15. LISTAR HASHES NOVOS
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_new_hashes;

    CREATE TEMPORARY TABLE tmp_z17_new_hashes (
        reconciliation_hash BINARY(16) NOT NULL,
        PRIMARY KEY (reconciliation_hash)
    );

    INSERT INTO tmp_z17_new_hashes (
        reconciliation_hash
    )
    SELECT reconciliation_hash
    FROM tmp_z17_existing_summary
    WHERE bronze_item_count = 0;


    /*
    ===========================================================================
    16. IDENTIFICAR COLUNAS COMPATÍVEIS PARA CARGA
    ===========================================================================
    */

    SELECT
        GROUP_CONCAT(
            CONCAT('`', s.COLUMN_NAME, '`')
            ORDER BY s.ORDINAL_POSITION
            SEPARATOR ', '
        ),
        GROUP_CONCAT(
            CONCAT('s.`', s.COLUMN_NAME, '`')
            ORDER BY s.ORDINAL_POSITION
            SEPARATOR ', '
        )
    INTO
        v_insert_columns,
        v_select_columns
    FROM information_schema.COLUMNS s
    WHERE s.TABLE_SCHEMA = 'bp_datalake'
      AND s.TABLE_NAME = 'stg_zsdbil17_faturamento'
      AND s.COLUMN_NAME NOT IN (
          'id',
          'source_status',
          'first_seen_at',
          'last_seen_at',
          'missing_since'
      )
      AND EXISTS (
          SELECT 1
          FROM information_schema.COLUMNS b
          WHERE b.TABLE_SCHEMA = 'bp_datalake'
            AND b.TABLE_NAME = 'bronze_zsdbil17_faturamento'
            AND b.COLUMN_NAME = s.COLUMN_NAME
      );

    IF v_insert_columns IS NULL
       OR v_select_columns IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: estrutura staging/Bronze incompatível.';
    END IF;


    /*
    ===========================================================================
    17. SUBSTITUIR DOCUMENTOS EXISTENTES PELO SNAPSHOT ATUAL
    ===========================================================================
    */

    DELETE b
    FROM bp_datalake.bronze_zsdbil17_faturamento b
    INNER JOIN tmp_z17_refresh_hashes r
        ON r.reconciliation_hash = b.reconciliation_hash;

    SET v_refresh_deleted_rows = ROW_COUNT();

    SET v_sql = CONCAT(
        '
        INSERT INTO bp_datalake.bronze_zsdbil17_faturamento (
            ',
            v_insert_columns,
            ',
            source_status,
            first_seen_at,
            last_seen_at,
            missing_since
        )
        SELECT
            ',
            v_select_columns,
            ',
            CASE
                WHEN TRIM(COALESCE(s.chave_de_acesso, '''')) = ''00''
                    THEN ''CANCELLED''
                ELSE ''ACTIVE''
            END,
            COALESCE(r.first_seen_at, NOW()),
            NOW(),
            NULL
        FROM bp_datalake.stg_zsdbil17_faturamento s
        INNER JOIN tmp_z17_refresh_hashes r
            ON r.reconciliation_hash = s.reconciliation_hash
        '
    );

    SET @sql_reconcile_z17 = v_sql;

    PREPARE stmt FROM @sql_reconcile_z17;
    SET v_stmt_prepared = TRUE;

    EXECUTE stmt;

    SET v_refreshed_rows = ROW_COUNT();

    DEALLOCATE PREPARE stmt;
    SET v_stmt_prepared = FALSE;
    SET @sql_reconcile_z17 = NULL;

    IF v_refresh_deleted_rows <> v_refreshed_rows THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT =
            'Reconciliacao Z17 bloqueada: refresh gerou quantidade diferente entre DELETE e INSERT.';
    END IF;


    /*
    ===========================================================================
    18. INSERIR DOCUMENTOS NOVOS
    ===========================================================================
    */

    SET v_sql = CONCAT(
        '
        INSERT INTO bp_datalake.bronze_zsdbil17_faturamento (
            ',
            v_insert_columns,
            ',
            source_status,
            first_seen_at,
            last_seen_at,
            missing_since
        )
        SELECT
            ',
            v_select_columns,
            ',
            CASE
                WHEN TRIM(COALESCE(s.chave_de_acesso, '''')) = ''00''
                    THEN ''CANCELLED''
                ELSE ''ACTIVE''
            END,
            NOW(),
            NOW(),
            NULL
        FROM bp_datalake.stg_zsdbil17_faturamento s
        INNER JOIN tmp_z17_new_hashes n
            ON n.reconciliation_hash = s.reconciliation_hash
        '
    );

    SET @sql_reconcile_z17 = v_sql;

    PREPARE stmt FROM @sql_reconcile_z17;
    SET v_stmt_prepared = TRUE;

    EXECUTE stmt;

    SET v_inserted_rows = ROW_COUNT();

    DEALLOCATE PREPARE stmt;
    SET v_stmt_prepared = FALSE;
    SET @sql_reconcile_z17 = NULL;


    /*
    ===========================================================================
    19. RESUMIR BRONZE DENTRO DAS DATAS RECEBIDAS
    ===========================================================================

    Essa tabela temporária existe exclusivamente para descobrir
    possíveis documentos MISSING.

    Não analisamos toda a Bronze histórica.
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_bronze_scope;


    CREATE TEMPORARY TABLE tmp_z17_bronze_scope (

        reconciliation_hash BINARY(16) NOT NULL,

        item_count INT NOT NULL,

        eligible_missing_rows INT NOT NULL,

        PRIMARY KEY (reconciliation_hash)

    );


    INSERT INTO tmp_z17_bronze_scope (
        reconciliation_hash,
        item_count,
        eligible_missing_rows
    )

    SELECT

        b.reconciliation_hash,

        COUNT(*) AS item_count,


        /*
        CANCELLED não deve ser rebaixado para MISSING.
        */

        SUM(
            CASE

                WHEN COALESCE(
                    b.source_status,
                    'UNKNOWN'
                ) <> 'CANCELLED'

                    THEN 1

                ELSE 0

            END
        ) AS eligible_missing_rows


    FROM bp_datalake.bronze_zsdbil17_faturamento b

    INNER JOIN tmp_z17_scope_dates d

        ON d.issuance_date =
           b.issuance_date


    WHERE b.reconciliation_hash IS NOT NULL


    GROUP BY
        b.reconciliation_hash;


    /*
    ===========================================================================
    20. IDENTIFICAR DOCUMENTOS MISSING
    ===========================================================================

    Regra:

        existe na Bronze
        +
        issuance_date está dentro do snapshot
        +
        reconciliation_hash não existe na staging
        +
        documento não está CANCELLED

        =
        MISSING
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_missing_hashes;


    CREATE TEMPORARY TABLE tmp_z17_missing_hashes (

        reconciliation_hash BINARY(16) NOT NULL,

        PRIMARY KEY (reconciliation_hash)

    );


    INSERT INTO tmp_z17_missing_hashes (
        reconciliation_hash
    )

    SELECT
        b.reconciliation_hash

    FROM tmp_z17_bronze_scope b

    LEFT JOIN tmp_z17_stg_summary s

        ON s.reconciliation_hash =
           b.reconciliation_hash


    WHERE s.reconciliation_hash IS NULL

      AND b.eligible_missing_rows > 0;


    SELECT COUNT(*)
    INTO v_missing_hashes

    FROM tmp_z17_missing_hashes;


    /*
    ===========================================================================
    21. MARCAR DOCUMENTOS COMO MISSING
    ===========================================================================
    */

    UPDATE bp_datalake.bronze_zsdbil17_faturamento b

    INNER JOIN tmp_z17_missing_hashes m

        ON m.reconciliation_hash =
           b.reconciliation_hash


    SET
        b.source_status = 'MISSING',

        b.missing_since =
            COALESCE(
                b.missing_since,
                NOW()
            )


    WHERE COALESCE(
              b.source_status,
              'UNKNOWN'
          ) <> 'CANCELLED';


    SET v_missing_updated =
        ROW_COUNT();


    /*
    ===========================================================================
    22. CONFIRMAR ALTERAÇÕES
    ===========================================================================
    */

    COMMIT;


    /*
    ===========================================================================
    23. LIMPEZA
    ===========================================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_z17_scope_dates;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_stg_summary;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_existing_summary;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_refresh_hashes;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_new_hashes;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_bronze_scope;
    DROP TEMPORARY TABLE IF EXISTS tmp_z17_missing_hashes;


    SET SESSION group_concat_max_len =
        v_old_group_concat_max_len;


    SET v_finished_at = NOW();


    /*
    ===========================================================================
    24. REGISTRAR EXECUÇÃO COM SUCESSO
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
        audit_details,
        execution_duration_seconds
    )

    VALUES (
        'sp_stg_reconcile_zsdbil17_bronze',
        'stg_zsdbil17_faturamento',
        'bronze_zsdbil17_faturamento',
        'SUCCESS',

        CURRENT_USER(),

        v_started_at,
        v_finished_at,

        v_source_rows,

        v_staging_hashes,

        v_inserted_rows,

        (
            v_active_updated
            + v_cancelled_updated
            + v_missing_updated
        ),

        (
            v_invalid_identity_rows
            + v_count_mismatch_hashes
            + v_mixed_status_hashes
        ),

        NULL,
        NULL,

        JSON_OBJECT(

            'scope_dates',
            v_scope_dates,

            'hashes_generated',
            v_hashes_generated,

            'staging_hashes',
            v_staging_hashes,

            'existing_hashes',
            v_existing_hashes,

            'new_hashes',
            v_new_hashes,

            'refreshed_hashes',
            v_refreshed_hashes,

            'refreshed_rows',
            v_refreshed_rows,

            'missing_hashes',
            v_missing_hashes,

            'count_mismatch_hashes',
            v_count_mismatch_hashes,

            'mixed_status_hashes',
            v_mixed_status_hashes,

            'invalid_identity_rows',
            v_invalid_identity_rows,

            'active_rows_updated',
            v_active_updated,

            'cancelled_rows_updated',
            v_cancelled_updated,

            'missing_rows_updated',
            v_missing_updated
        ),

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        )
    );


    SET v_execution_id =
        LAST_INSERT_ID();


    /*
    ===========================================================================
    25. RETORNO PARA QUEM EXECUTOU A PROCEDURE
    ===========================================================================

    Esse SELECT permite enxergar imediatamente o resultado no DBeaver,
    mesmo sem consultar a tabela de log.
    */

    SELECT

        v_execution_id
            AS execution_id,

        v_source_rows
            AS staging_rows,

        v_scope_dates
            AS datas_reconciliadas,
        
        v_hashes_generated
            AS linhas_hash_gerado,

        v_staging_hashes
            AS hashes_staging,

        v_existing_hashes
            AS hashes_existentes,

        v_new_hashes
            AS hashes_novos,

        v_refreshed_hashes
            AS hashes_atualizados,

        v_refreshed_rows
            AS linhas_atualizadas_snapshot,

        v_missing_hashes
            AS hashes_missing,

        v_count_mismatch_hashes
            AS hashes_count_diferente,

        v_mixed_status_hashes
            AS hashes_status_misto,

        v_inserted_rows
            AS linhas_inseridas,

        v_active_updated
            AS linhas_active,

        v_cancelled_updated
            AS linhas_cancelled,

        v_missing_updated
            AS linhas_missing,

        TIMESTAMPDIFF(
            SECOND,
            v_started_at,
            v_finished_at
        )
            AS duracao_segundos;


END$$

DELIMITER ;
