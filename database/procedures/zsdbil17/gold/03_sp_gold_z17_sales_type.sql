/*
============================================================
ZSDBIL17 - GOLD
03 - SALES TYPE CLASSIFICATION
============================================================

Escopo: só linhas que não são Legacy 2024/2025.

Até 23/11/2026 a Gold era apagada a cada execução e o Legacy
só entrava depois desta procedure. Agora o Legacy fica na
tabela entre as execuções (ADR-050 do sap_service), então
toda leitura e gravação daqui filtra
NOT (record_source <=> 'LEGACY_2024_2025') para manter o
resultado de antes (o Legacy guarda a divisão que veio da
planilha histórica). <=> trata NULL como valor.
============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_gold_z17_sales_type;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_gold_z17_sales_type()
BEGIN

    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_division_classified BIGINT DEFAULT 0;
    DECLARE v_cfop_classified BIGINT DEFAULT 0;
    DECLARE v_unknown_rows BIGINT DEFAULT 0;


    /*
    ============================================================
    1. TOTAL DE REGISTROS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.gold_zsdbil17_faturamento AS g
    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025');


    /*
    ============================================================
    2. CLASSIFICAÇÃO PRINCIPAL POR DIVISION
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_sales_order_type AS d
        ON TRIM(g.division) = TRIM(d.sales_order_type)

    SET
        g.division_description =
            NULLIF(
                TRIM(d.sales_order_type_description),
                ''
            )

    WHERE
        NOT (g.record_source <=> 'LEGACY_2024_2025')

        AND NULLIF(
            TRIM(d.sales_order_type_description),
            ''
        ) IS NOT NULL;


    /*
    Métrica real:
    quantos registros ficaram classificados
    por uma division existente na dimensão.
    */

    SELECT COUNT(*)
    INTO v_division_classified

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_sales_order_type AS d
        ON TRIM(g.division) = TRIM(d.sales_order_type)

    WHERE
        NOT (g.record_source <=> 'LEGACY_2024_2025')

        AND NULLIF(
            TRIM(d.sales_order_type_description),
            ''
        ) IS NOT NULL;


    /*
    ============================================================
    3. FALLBACK POR CFOP
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    INNER JOIN bp_datalake.dim_cfop_sales_type AS d
        ON TRIM(g.cfop) = TRIM(d.cfop)

    SET
        g.division_description =
            NULLIF(
                TRIM(d.sales_type),
                ''
            )

    WHERE
        NOT (g.record_source <=> 'LEGACY_2024_2025')

        AND NULLIF(
            TRIM(g.division_description),
            ''
        ) IS NULL

        AND NULLIF(
            TRIM(d.sales_type),
            ''
        ) IS NOT NULL;


    /*
    Métrica real:
    registros que NÃO tinham division válida,
    mas conseguiram classificação pelo CFOP.
    */

    SELECT COUNT(*)
    INTO v_cfop_classified

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    LEFT JOIN bp_datalake.dim_sales_order_type AS s
        ON TRIM(g.division) = TRIM(s.sales_order_type)

    INNER JOIN bp_datalake.dim_cfop_sales_type AS c
        ON TRIM(g.cfop) = TRIM(c.cfop)

    WHERE
        NOT (g.record_source <=> 'LEGACY_2024_2025')

        AND NULLIF(
            TRIM(s.sales_order_type_description),
            ''
        ) IS NULL

        AND NULLIF(
            TRIM(c.sales_type),
            ''
        ) IS NOT NULL;


    /*
    ============================================================
    4. REGISTROS SEM CLASSIFICAÇÃO
    ============================================================
    */

    UPDATE bp_datalake.gold_zsdbil17_faturamento AS g

    SET g.division_description = 'UNKNOWN'

    WHERE
        NOT (g.record_source <=> 'LEGACY_2024_2025')

        AND NULLIF(
            TRIM(division_description),
            ''
        ) IS NULL;


    /*
    Métrica final UNKNOWN
    */

    SELECT COUNT(*)
    INTO v_unknown_rows

    FROM bp_datalake.gold_zsdbil17_faturamento AS g

    WHERE NOT (g.record_source <=> 'LEGACY_2024_2025')
      AND g.division_description = 'UNKNOWN';


    /*
    ============================================================
    5. RESULTADO
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_source_rows AS source_rows,
        v_division_classified AS division_classified_rows,
        v_cfop_classified AS cfop_fallback_rows,
        v_unknown_rows AS unknown_rows,

        (
            v_division_classified
            + v_cfop_classified
            + v_unknown_rows
        ) AS accounted_rows;

END$$

DELIMITER ;
