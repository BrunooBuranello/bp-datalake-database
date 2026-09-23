/*
============================================================
ZSDBIL17 - SILVER
06 - SALES TYPE CLASSIFICATION
============================================================

Objetivo:
Enriquecer o histórico da Silver com a classificação
de tipo de venda.

Coluna gerenciada pela própria procedure:
    division_description_enriched

Prioridade:
1. DIVISION -> dim_sales_order_type
2. CFOP     -> dim_cfop_sales_type
3. UNKNOWN

A coluna original division_description é preservada.
============================================================
*/

DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_z17_sales_type;

DELIMITER $$

CREATE PROCEDURE bp_datalake.sp_silver_z17_sales_type()
BEGIN

    DECLARE v_column_exists INT DEFAULT 0;
    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_demo_rows BIGINT DEFAULT 0;
    DECLARE v_unknown_rows BIGINT DEFAULT 0;


    /*
    ============================================================
    1. VERIFICA SE A COLUNA DE ENRIQUECIMENTO EXISTE
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_column_exists
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = 'bp_datalake'
      AND TABLE_NAME = 'silver_zsdbil17_outbound_movements'
      AND COLUMN_NAME = 'division_description_enriched';


    /*
    ============================================================
    2. CRIA A COLUNA SOMENTE SE NÃO EXISTIR
    ============================================================
    */

    IF v_column_exists = 0 THEN

        SET @sql_add_column = '
            ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
            ADD COLUMN division_description_enriched VARCHAR(100) NULL
            COMMENT ''Descrição da divisão enriquecida pelo Data Lake via Division, com fallback por CFOP''
        ';

        PREPARE stmt_add_column FROM @sql_add_column;
        EXECUTE stmt_add_column;
        DEALLOCATE PREPARE stmt_add_column;

    END IF;


    /*
    ============================================================
    3. TOTAL DE REGISTROS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_source_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements;


    /*
    ============================================================
    4. ENRIQUECIMENTO
    ============================================================

    Prioridade:
        Division
        ↓
        CFOP
        ↓
        UNKNOWN

    Importante:
    division_description original do SAP não é alterada.
    ============================================================
    */

    UPDATE bp_datalake.silver_zsdbil17_outbound_movements AS s

    LEFT JOIN bp_datalake.dim_sales_order_type AS d_sales
        ON TRIM(s.division) = TRIM(d_sales.sales_order_type)

    LEFT JOIN bp_datalake.dim_cfop_sales_type AS d_cfop
        ON TRIM(s.cfop) = TRIM(d_cfop.cfop)

    SET
        s.division_description_enriched =
            COALESCE(
                NULLIF(
                    TRIM(d_sales.sales_order_type_description),
                    ''
                ),
                NULLIF(
                    TRIM(d_cfop.sales_type),
                    ''
                ),
                'UNKNOWN'
            );


    /*
    ============================================================
    5. MÉTRICAS
    ============================================================
    */

    SELECT COUNT(*)
    INTO v_demo_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE division_description_enriched = 'Demo';


    SELECT COUNT(*)
    INTO v_unknown_rows
    FROM bp_datalake.silver_zsdbil17_outbound_movements
    WHERE division_description_enriched = 'UNKNOWN';


    /*
    ============================================================
    6. RESULTADO
    ============================================================
    */

    SELECT
        'SUCCESS' AS execution_status,
        v_source_rows AS source_rows,
        v_demo_rows AS demo_rows,
        v_unknown_rows AS unknown_rows;

END$$

DELIMITER ;
