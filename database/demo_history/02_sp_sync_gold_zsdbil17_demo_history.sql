/*
============================================================
ZSDBIL17 - DEMO HISTORY
02 - SYNC DEMO HISTORY
============================================================

Fonte:
    bp_datalake.silver_zsdbil17_outbound_movements

Objetivo:
    Identificar faturamentos DEMO válidos na Silver e
    preservar todas as movimentações posteriores do mesmo
    chassi dentro de um ciclo histórico independente.

Regras para iniciar um ciclo DEMO:

    division_description_enriched = 'Demo'
    cfop_car = 'Yes'
    chassis_serial_number = 17 caracteres
    invoice_number preenchida
    issuance_date preenchida

A chave de acesso NÃO é utilizada como filtro de entrada.

Eventos:

    event_sequence = 1
        DEMO

    event_sequence > 1
        REINVOICE

    Caso uma movimentação posterior esteja CANCELLED:
        CANCELLATION

Status do ciclo:

    OPEN
    WARNING     -> a partir de 20 dias
    OVERDUE     -> após 30 dias
    CLOSED      -> existe faturamento posterior não cancelado
                   OU existe um novo DEMO posterior do mesmo chassi

Identidade de negócio:

    demo_cycle_key
        CHASSI-PLANT-NOTA_DEMO-CHAVE_DE_ACESSO_DEMO
        Identifica o ciclo iniciado pelo DEMO original.
        A mesma chave é repetida em todos os eventos do ciclo.

    document_key
        CHASSI-PLANT-NOTA-CHAVE_DE_ACESSO
        Identifica o documento/evento da linha.

Um novo DEMO do mesmo chassi encerra o ciclo anterior
e inicia um novo ciclo.

IMPORTANTE:
    Esta procedure NÃO executa DELETE ou TRUNCATE na tabela
    gold_zsdbil17_demo_history.

    Novos eventos são inseridos.
    Eventos já existentes são atualizados via UPSERT.

    first_seen_at é preservado.
    last_seen_at é atualizado quando o evento volta a ser visto.

    warning_sent_at e overdue_sent_at pertencem ao módulo de
    notificações e NÃO são alterados por esta procedure.

============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_sync_gold_zsdbil17_demo_history;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_sync_gold_zsdbil17_demo_history()
BEGIN

    DECLARE v_demo_cycles BIGINT DEFAULT 0;
    DECLARE v_events_found BIGINT DEFAULT 0;
    DECLARE v_rows_affected BIGINT DEFAULT 0;


    /*
    ============================================================
    1. LIMPEZA DAS TABELAS TEMPORÁRIAS
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_demo_seeds;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_chassis;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_movements;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_events;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_events_status;


    /*
    ============================================================
    2. IDENTIFICA FATURAMENTOS DEMO VÁLIDOS
    ============================================================

    Critérios:

    - classificação enriquecida = Demo
    - CFOP de veículo = Yes
    - chassi preenchido
    - chassi com exatamente 17 caracteres
    - NF preenchida
    - data de emissão preenchida

    Caso existam múltiplas linhas para o mesmo
    chassi + NF, usamos a mais recente pela dt_carga.
    ============================================================
    */

    CREATE TEMPORARY TABLE tmp_demo_seeds AS

    SELECT
        d.chassis_serial_number,
        d.invoice_number AS demo_invoice_number,
        d.issuance_date AS demo_issuance_date,
        d.dt_carga AS demo_dt_carga,
        d.plant_code AS demo_plant_code,
        d.chave_de_acesso AS demo_chave_de_acesso,

        CASE
            WHEN d.plant_code IS NOT NULL
             AND d.chave_de_acesso IS NOT NULL
            THEN CONCAT(
                d.chassis_serial_number, '-',
                d.plant_code, '-',
                d.invoice_number, '-',
                d.chave_de_acesso
            )
            ELSE NULL
        END AS demo_cycle_key,

        LEAD(d.issuance_date) OVER (
            PARTITION BY d.chassis_serial_number
            ORDER BY
                d.issuance_date,
                COALESCE(
                    d.dt_carga,
                    TIMESTAMP(d.issuance_date)
                ),
                d.invoice_number
        ) AS next_demo_date,

        LEAD(d.dt_carga) OVER (
            PARTITION BY d.chassis_serial_number
            ORDER BY
                d.issuance_date,
                COALESCE(
                    d.dt_carga,
                    TIMESTAMP(d.issuance_date)
                ),
                d.invoice_number
        ) AS next_demo_dt_carga,

        LEAD(d.invoice_number) OVER (
            PARTITION BY d.chassis_serial_number
            ORDER BY
                d.issuance_date,
                COALESCE(
                    d.dt_carga,
                    TIMESTAMP(d.issuance_date)
                ),
                d.invoice_number
        ) AS next_demo_invoice

    FROM (

        SELECT
            TRIM(s.chassis_serial_number)
                AS chassis_serial_number,

            TRIM(s.invoice_number)
                AS invoice_number,

            NULLIF(TRIM(s.plant_code), '')
                AS plant_code,

            NULLIF(TRIM(s.chave_de_acesso), '')
                AS chave_de_acesso,

            s.issuance_date,
            s.dt_carga,

            ROW_NUMBER() OVER (
                PARTITION BY
                    TRIM(s.chassis_serial_number),
                    TRIM(s.invoice_number)

                ORDER BY
                    COALESCE(
                        s.dt_carga,
                        TIMESTAMP(s.issuance_date)
                    ) DESC,

                    COALESCE(
                        s.sap_document,
                        ''
                    ) DESC
            ) AS rn

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        WHERE
            TRIM(s.division_description_enriched) = 'Demo'

            AND UPPER(
                TRIM(s.cfop_car)
            ) = 'YES'

            AND NULLIF(
                TRIM(s.chassis_serial_number),
                ''
            ) IS NOT NULL

            AND CHAR_LENGTH(
                TRIM(s.chassis_serial_number)
            ) = 17

            AND NULLIF(
                TRIM(s.invoice_number),
                ''
            ) IS NOT NULL

            AND s.issuance_date IS NOT NULL

    ) AS d

    WHERE d.rn = 1;


    /*
    ============================================================
    3. TOTAL DE CICLOS DEMO IDENTIFICADOS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_demo_cycles
    FROM tmp_demo_seeds;


    /*
    ============================================================
    4. CHASSIS QUE POSSUEM HISTÓRICO DEMO
    ============================================================
    */

    CREATE TEMPORARY TABLE tmp_demo_chassis AS

    SELECT DISTINCT
        chassis_serial_number

    FROM tmp_demo_seeds;


    /*
    ============================================================
    5. MOVIMENTAÇÕES DOS CHASSIS DEMO
    ============================================================

    Aqui buscamos todas as NFs de veículo dos chassis
    que em algum momento tiveram um faturamento DEMO.

    A movimentação posterior NÃO precisa continuar sendo DEMO.

    Critérios:

    - CFOP de veículo = Yes
    - chassi com 17 caracteres
    - NF preenchida
    - data preenchida

    Caso a Silver tenha mais de uma linha para a mesma
    combinação chassi + NF, usamos a versão mais recente.
    ============================================================
    */

    CREATE TEMPORARY TABLE tmp_demo_movements AS

    SELECT
        CASE
            WHEN m.plant_code IS NOT NULL
             AND m.chave_de_acesso IS NOT NULL
            THEN CONCAT(
                m.chassis_serial_number, '-',
                m.plant_code, '-',
                m.invoice_number, '-',
                m.chave_de_acesso
            )
            ELSE NULL
        END AS document_key,

        m.chave_de_acesso,
        m.chassis_serial_number,

        m.division,
        m.division_description,
        m.division_description_enriched,

        m.invoice_number,
        m.issuance_date,

        m.material,
        m.description,

        m.sold_to_party_code,
        m.sold_to_party_cnpj,
        m.sold_to_party_name,
        m.sold_to_party_state,

        m.ship_to_party_code,
        m.ship_to_party_cnpj,
        m.ship_to_party_name,
        m.ship_to_party_state,

        m.payment_condition,
        m.payment_condition_description_dim,

        m.ncm,
        m.cfop,
        m.cfop_car,

        m.access_key_status,

        m.plant_code,
        m.plant_description,

        m.sap_document,
        m.billing_number_vf01,

        m.origem_chassi,

        m.source_file,
        m.dt_carga

    FROM (

        SELECT
            NULLIF(TRIM(s.chave_de_acesso), '')
                AS chave_de_acesso,

            TRIM(s.chassis_serial_number)
                AS chassis_serial_number,

            s.division,
            s.division_description,
            s.division_description_enriched,

            TRIM(s.invoice_number)
                AS invoice_number,

            s.issuance_date,

            s.material,
            s.description,

            s.sold_to_party_code,
            s.sold_to_party_cnpj,
            s.sold_to_party_name,
            s.sold_to_party_state,

            s.ship_to_party_code,
            s.ship_to_party_cnpj,
            s.ship_to_party_name,
            s.ship_to_party_state,

            s.payment_condition,

            /*
            Campo atualmente inexistente na Silver.
            Mantido NULL no histórico.
            */
            CAST(NULL AS CHAR(255))
                AS payment_condition_description_dim,

            s.ncm,
            s.cfop,
            s.cfop_car,

            s.access_key_status,

            NULLIF(TRIM(s.plant_code), '')
                AS plant_code,

            /*
            Campo atualmente inexistente na Silver.
            Mantido NULL no histórico.
            */
            CAST(NULL AS CHAR(100))
                AS plant_description,

            s.sap_document,
            s.billing_number_vf01,

            /*
            Campo atualmente inexistente na Silver.
            Mantido NULL no histórico.
            */
            CAST(NULL AS CHAR(20))
                AS origem_chassi,

            s.source_file,
            s.dt_carga,

            ROW_NUMBER() OVER (
                PARTITION BY
                    TRIM(s.chassis_serial_number),
                    TRIM(s.invoice_number)

                ORDER BY
                    COALESCE(
                        s.dt_carga,
                        TIMESTAMP(s.issuance_date)
                    ) DESC,

                    COALESCE(
                        s.sap_document,
                        ''
                    ) DESC
            ) AS rn

        FROM bp_datalake.silver_zsdbil17_outbound_movements AS s

        INNER JOIN tmp_demo_chassis AS d
            ON d.chassis_serial_number =
               TRIM(s.chassis_serial_number)

        WHERE
            UPPER(
                TRIM(s.cfop_car)
            ) = 'YES'

            AND CHAR_LENGTH(
                TRIM(s.chassis_serial_number)
            ) = 17

            AND NULLIF(
                TRIM(s.invoice_number),
                ''
            ) IS NOT NULL

            AND s.issuance_date IS NOT NULL

    ) AS m

    WHERE m.rn = 1;


    /*
    ============================================================
    6. MONTA OS EVENTOS DO CICLO DEMO
    ============================================================

    Para cada DEMO:

        sequence 1
            própria NF DEMO

        sequence 2+
            movimentações posteriores do mesmo chassi

    Caso o mesmo chassi tenha outro DEMO posteriormente,
    esse novo DEMO inicia outro ciclo.

    O ciclo anterior não atravessa para dentro do próximo.
    ============================================================
    */

    CREATE TEMPORARY TABLE tmp_demo_events AS

    SELECT
        e.*,

        ROW_NUMBER() OVER (
            PARTITION BY
                e.chassis_serial_number,
                e.demo_origin_invoice_number

            ORDER BY
                e.issuance_date,

                COALESCE(
                    e.dt_carga,
                    TIMESTAMP(e.issuance_date)
                ),

                e.invoice_number
        ) AS event_sequence

    FROM (

        SELECT
            s.demo_invoice_number
                AS demo_origin_invoice_number,

            s.demo_issuance_date,
            s.demo_cycle_key,
            s.next_demo_date,
            s.next_demo_dt_carga,

            m.document_key,
            m.chave_de_acesso,
            m.chassis_serial_number,

            m.division,
            m.division_description,
            m.division_description_enriched,

            m.invoice_number,
            m.issuance_date,

            m.material,
            m.description,

            m.sold_to_party_code,
            m.sold_to_party_cnpj,
            m.sold_to_party_name,
            m.sold_to_party_state,

            m.ship_to_party_code,
            m.ship_to_party_cnpj,
            m.ship_to_party_name,
            m.ship_to_party_state,

            m.payment_condition,
            m.payment_condition_description_dim,

            m.ncm,
            m.cfop,
            m.cfop_car,

            m.access_key_status,

            m.plant_code,
            m.plant_description,

            m.sap_document,
            m.billing_number_vf01,

            m.origem_chassi,

            m.source_file,
            m.dt_carga

        FROM tmp_demo_seeds AS s

        INNER JOIN tmp_demo_movements AS m

            ON m.chassis_serial_number =
               s.chassis_serial_number

            AND (

                /*
                A própria NF DEMO.
                */
                m.invoice_number =
                    s.demo_invoice_number

                OR

                /*
                Movimentações em datas posteriores.
                */
                m.issuance_date >
                    s.demo_issuance_date

                OR

                /*
                Movimentações no mesmo dia,
                mas carregadas posteriormente.
                */
                (
                    m.issuance_date =
                        s.demo_issuance_date

                    AND COALESCE(
                            m.dt_carga,
                            TIMESTAMP(m.issuance_date)
                        )
                        >
                        COALESCE(
                            s.demo_dt_carga,
                            TIMESTAMP(s.demo_issuance_date)
                        )
                )

                OR

                /*
                Desempate final para registros com mesma
                data e mesma dt_carga.
                */
                (
                    m.issuance_date =
                        s.demo_issuance_date

                    AND COALESCE(
                            m.dt_carga,
                            TIMESTAMP(m.issuance_date)
                        )
                        =
                        COALESCE(
                            s.demo_dt_carga,
                            TIMESTAMP(s.demo_issuance_date)
                        )

                    AND m.invoice_number >
                        s.demo_invoice_number
                )
            )


            /*
            Limite do ciclo:
            não atravessar para outro DEMO do mesmo chassi.
            */
            AND (

                s.next_demo_date IS NULL

                OR m.issuance_date <
                    s.next_demo_date

                OR (
                    m.issuance_date =
                        s.next_demo_date

                    AND (
                        COALESCE(
                            m.dt_carga,
                            TIMESTAMP(m.issuance_date)
                        )
                        <
                        COALESCE(
                            s.next_demo_dt_carga,
                            TIMESTAMP(s.next_demo_date)
                        )

                        OR (
                            COALESCE(
                                m.dt_carga,
                                TIMESTAMP(m.issuance_date)
                            )
                            =
                            COALESCE(
                                s.next_demo_dt_carga,
                                TIMESTAMP(s.next_demo_date)
                            )

                            AND m.invoice_number <
                                s.next_demo_invoice
                        )
                    )
                )
            )

    ) AS e;


    /*
    ============================================================
    7. CALCULA STATUS E FECHAMENTO DO CICLO
    ============================================================

    Uma movimentação posterior CANCELLED:

        - permanece no histórico;
        - não fecha o ciclo sozinha.

    A primeira movimentação posterior não cancelada:

        - encerra o ciclo DEMO.

    A própria NF DEMO CANCELLED também encerra o ciclo.

    Se não houver movimentação válida antes do próximo DEMO,
    o próximo DEMO encerra o ciclo anterior e inicia outro ciclo.
    ============================================================
    */

    CREATE TEMPORARY TABLE tmp_demo_events_status AS

    SELECT
        x.*,

        CASE

            WHEN x.origin_cancelled = 1
                THEN 'CLOSED'

            WHEN x.first_valid_next_invoice IS NOT NULL
                THEN 'CLOSED'

            WHEN x.next_demo_date IS NOT NULL
                THEN 'CLOSED'

            WHEN CURRENT_DATE >
                 DATE_ADD(
                     x.demo_issuance_date,
                     INTERVAL 30 DAY
                 )
                THEN 'OVERDUE'

            WHEN CURRENT_DATE >=
                 DATE_ADD(
                     x.demo_issuance_date,
                     INTERVAL 20 DAY
                 )
                THEN 'WARNING'

            ELSE 'OPEN'

        END AS demo_status,


        CASE

            WHEN x.origin_cancelled = 1
                THEN TIMESTAMP(
                    x.demo_issuance_date
                )

            WHEN x.first_valid_next_invoice IS NOT NULL
                THEN TIMESTAMP(
                    x.first_valid_next_invoice
                )

            WHEN x.next_demo_date IS NOT NULL
                THEN TIMESTAMP(
                    x.next_demo_date
                )

            ELSE NULL

        END AS closed_at

    FROM (

        SELECT
            e.*,

            /*
            Identifica se a própria NF DEMO
            encontra-se cancelada.
            */
            MAX(
                CASE

                    WHEN e.event_sequence = 1

                     AND UPPER(
                            COALESCE(
                                TRIM(e.access_key_status),
                                ''
                            )
                         ) = 'CANCELLED'

                    THEN 1

                    ELSE 0

                END
            ) OVER (
                PARTITION BY
                    e.chassis_serial_number,
                    e.demo_origin_invoice_number
            ) AS origin_cancelled,


            /*
            Localiza a primeira movimentação posterior
            válida e não cancelada.
            */
            MIN(
                CASE

                    WHEN e.event_sequence > 1

                     AND UPPER(
                            COALESCE(
                                TRIM(e.access_key_status),
                                ''
                            )
                         ) <> 'CANCELLED'

                    THEN e.issuance_date

                END
            ) OVER (
                PARTITION BY
                    e.chassis_serial_number,
                    e.demo_origin_invoice_number
            ) AS first_valid_next_invoice

        FROM tmp_demo_events AS e

    ) AS x;


    /*
    ============================================================
    8. TOTAL DE EVENTOS LOCALIZADOS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_events_found
    FROM tmp_demo_events_status;


    /*
    ============================================================
    9. INSERT / UPDATE DO HISTÓRICO
    ============================================================

    A tabela histórica NÃO é apagada.

    Novo evento:
        INSERT

    Evento já existente:
        UPDATE

    Se uma movimentação desaparecer da Silver posteriormente,
    o registro já existente no histórico não é removido.

    first_seen_at não é atualizado.
    warning_sent_at e overdue_sent_at não participam do UPSERT.
    ============================================================
    */

    INSERT INTO bp_datalake.gold_zsdbil17_demo_history (

        demo_cycle_key,
        document_key,

        demo_origin_invoice_number,
        event_sequence,
        event_type,
        demo_status,

        demo_started_at,
        warning_date,
        due_date,
        closed_at,

        chave_de_acesso,
        chassis_serial_number,

        division,
        division_description,
        division_description_enriched,

        invoice_number,
        issuance_date,

        material,
        description,

        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,

        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,

        payment_condition,
        payment_condition_description_dim,

        ncm,
        cfop,
        cfop_car,

        access_key_status,

        plant_code,
        plant_description,

        sap_document,
        billing_number_vf01,

        origem_chassi,

        source_file,
        dt_carga

    )

    SELECT

        demo_cycle_key,
        document_key,

        demo_origin_invoice_number,

        event_sequence,

        CASE

            WHEN event_sequence = 1
                THEN 'DEMO'

            WHEN UPPER(
                    COALESCE(
                        TRIM(access_key_status),
                        ''
                    )
                 ) = 'CANCELLED'
                THEN 'CANCELLATION'

            ELSE 'REINVOICE'

        END AS event_type,

        demo_status,

        TIMESTAMP(
            demo_issuance_date
        ) AS demo_started_at,

        DATE_ADD(
            demo_issuance_date,
            INTERVAL 20 DAY
        ) AS warning_date,

        DATE_ADD(
            demo_issuance_date,
            INTERVAL 30 DAY
        ) AS due_date,

        closed_at,

        chave_de_acesso,
        chassis_serial_number,

        division,
        division_description,
        division_description_enriched,

        invoice_number,
        issuance_date,

        material,
        description,

        sold_to_party_code,
        sold_to_party_cnpj,
        sold_to_party_name,
        sold_to_party_state,

        ship_to_party_code,
        ship_to_party_cnpj,
        ship_to_party_name,
        ship_to_party_state,

        payment_condition,
        payment_condition_description_dim,

        ncm,
        cfop,
        cfop_car,

        access_key_status,

        plant_code,
        plant_description,

        sap_document,
        billing_number_vf01,

        origem_chassi,

        source_file,
        dt_carga

    FROM tmp_demo_events_status


    ON DUPLICATE KEY UPDATE

        /*
        As chaves de negócio são estáveis:
        - se já foram gravadas, preservamos;
        - se ainda eram NULL, preenchemos quando a fonte permitir.
        */
        demo_cycle_key =
            COALESCE(
                bp_datalake.gold_zsdbil17_demo_history.demo_cycle_key,
                VALUES(demo_cycle_key)
            ),

        document_key =
            COALESCE(
                bp_datalake.gold_zsdbil17_demo_history.document_key,
                VALUES(document_key)
            ),

        event_sequence =
            VALUES(event_sequence),

        event_type =
            VALUES(event_type),

        /*
        CLOSED é terminal no histórico. Uma execução posterior
        não reabre o ciclo caso a movimentação deixe de aparecer
        momentaneamente na Silver.
        */
        demo_status =
            CASE
                WHEN bp_datalake.gold_zsdbil17_demo_history.demo_status = 'CLOSED'
                    THEN 'CLOSED'
                ELSE VALUES(demo_status)
            END,

        demo_started_at =
            VALUES(demo_started_at),

        warning_date =
            VALUES(warning_date),

        due_date =
            VALUES(due_date),

        /*
        A primeira data de fechamento confirmada é preservada.
        */
        closed_at =
            COALESCE(
                bp_datalake.gold_zsdbil17_demo_history.closed_at,
                VALUES(closed_at)
            ),

        chave_de_acesso =
            VALUES(chave_de_acesso),

        division =
            VALUES(division),

        division_description =
            VALUES(division_description),

        division_description_enriched =
            VALUES(division_description_enriched),

        issuance_date =
            VALUES(issuance_date),

        material =
            VALUES(material),

        description =
            VALUES(description),

        sold_to_party_code =
            VALUES(sold_to_party_code),

        sold_to_party_cnpj =
            VALUES(sold_to_party_cnpj),

        sold_to_party_name =
            VALUES(sold_to_party_name),

        sold_to_party_state =
            VALUES(sold_to_party_state),

        ship_to_party_code =
            VALUES(ship_to_party_code),

        ship_to_party_cnpj =
            VALUES(ship_to_party_cnpj),

        ship_to_party_name =
            VALUES(ship_to_party_name),

        ship_to_party_state =
            VALUES(ship_to_party_state),

        payment_condition =
            VALUES(payment_condition),

        payment_condition_description_dim =
            VALUES(payment_condition_description_dim),

        ncm =
            VALUES(ncm),

        cfop =
            VALUES(cfop),

        cfop_car =
            VALUES(cfop_car),

        access_key_status =
            VALUES(access_key_status),

        plant_code =
            VALUES(plant_code),

        plant_description =
            VALUES(plant_description),

        sap_document =
            VALUES(sap_document),

        billing_number_vf01 =
            VALUES(billing_number_vf01),

        origem_chassi =
            VALUES(origem_chassi),

        source_file =
            VALUES(source_file),

        dt_carga =
            VALUES(dt_carga),

        last_seen_at =
            CURRENT_TIMESTAMP;


    SET v_rows_affected = ROW_COUNT();


    /*
    ============================================================
    10. RESULTADO DA EXECUÇÃO
    ============================================================

    IMPORTANTE:

    OPEN / WARNING / OVERDUE / CLOSED são contabilizados
    somente no evento de origem (event_sequence = 1).

    Dessa forma contamos CICLOS DEMO e não todas as linhas
    pertencentes ao ciclo.
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,

        v_demo_cycles
            AS demo_cycles,

        v_events_found
            AS events_found,

        v_rows_affected
            AS affected_rows,


        /*
        Total de eventos armazenados.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

        ) AS history_rows,


        /*
        Total de chassis distintos presentes no histórico.
        */
        (
            SELECT COUNT(
                DISTINCT chassis_serial_number
            )

            FROM bp_datalake.gold_zsdbil17_demo_history

        ) AS chassis_count,


        /*
        Quantidade de ciclos DEMO armazenados.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

            WHERE event_sequence = 1

        ) AS demo_origin_events,


        /*
        Ciclos ainda dentro dos primeiros 20 dias.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

            WHERE event_sequence = 1
              AND demo_status = 'OPEN'

        ) AS open_cycles,


        /*
        Ciclos entre 20 e 30 dias.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

            WHERE event_sequence = 1
              AND demo_status = 'WARNING'

        ) AS warning_cycles,


        /*
        Ciclos acima de 30 dias ainda sem fechamento.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

            WHERE event_sequence = 1
              AND demo_status = 'OVERDUE'

        ) AS overdue_cycles,


        /*
        Ciclos encerrados.
        */
        (
            SELECT COUNT(*)

            FROM bp_datalake.gold_zsdbil17_demo_history

            WHERE event_sequence = 1
              AND demo_status = 'CLOSED'

        ) AS closed_cycles;


    /*
    ============================================================
    11. LIMPEZA DAS TABELAS TEMPORÁRIAS
    ============================================================
    */

    DROP TEMPORARY TABLE IF EXISTS tmp_demo_events_status;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_events;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_movements;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_chassis;
    DROP TEMPORARY TABLE IF EXISTS tmp_demo_seeds;

END$$

DELIMITER ;
