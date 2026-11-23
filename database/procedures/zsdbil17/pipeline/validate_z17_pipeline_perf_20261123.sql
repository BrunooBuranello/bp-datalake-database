/*
============================================================
ZSDBIL17 - VALIDAÇÃO DO DESEMPENHO DA PIPELINE (ADR-050)
============================================================

Arquivo:
validate_z17_pipeline_perf_20261123.sql

Objetivo:
Provar, na janela de deploy, que as procedures novas (itens 0,
1 e 2 do ADR-050 do sap_service) deixam a Gold IGUAL à das
procedures antigas, e medir o tempo de cada etapa.

Como (rodar em partes, na ordem, com a fila SAP parada e o
orquestrador desligado):

    PARTE A - antes de aplicar as procedures novas: rodar a
        pipeline ANTIGA uma vez e, logo em seguida, copiar a
        Gold. Assim as duas execuções usam as mesmas dimensões
        (CRM, Material Code, cancelamentos, Direct Sales) e
        qualquer diferença vem das procedures, não dos dados.

    Aplicar as procedures novas (README, seção "Desempenho da
    pipeline Z17") e rodar a pipeline UMA vez sobre a MESMA
    staging (sem baixar Z17 nova no meio).

    PARTE B - depois da pipeline
        diferença linha a linha: tem que dar 0 em tudo.

    PARTE C - tempo das etapas (inclui as 5 que passaram a
        ser registradas pela pipeline).

    PARTE D - limpeza da cópia (só depois de alguns dias, com
        confirmação do Bruno).

Comparação: todas as colunas de negócio, exata (BINARY), NULL
igual a NULL (<=>). Ficam de fora só as colunas técnicas da
carga: usuario, dt_carga_gold e id_execucao.
============================================================
*/


/*
============================================================
PARTE A - CÓPIA DA GOLD (ANTES DE APLICAR AS PROCEDURES)
============================================================
~435 mil linhas, ~560 MB. Também serve de rollback dos dados.
*/

CREATE TABLE bp_datalake.gold_zsdbil17_faturamento_bkp_20261123 AS
SELECT *
FROM bp_datalake.gold_zsdbil17_faturamento;

ALTER TABLE bp_datalake.gold_zsdbil17_faturamento_bkp_20261123
    ADD PRIMARY KEY (chassis_serial_number);

SELECT record_source, COUNT(*) AS linhas
FROM bp_datalake.gold_zsdbil17_faturamento_bkp_20261123
GROUP BY record_source;


/*
============================================================
PARTE B - DIFERENÇAS (DEPOIS DA PIPELINE NOVA)
============================================================
Esperado: 0, 0 e 0.
*/

-- B1. Chassi que estava na cópia e sumiu da Gold.
SELECT COUNT(*) AS chassi_sumiu
FROM bp_datalake.gold_zsdbil17_faturamento_bkp_20261123 AS b
LEFT JOIN bp_datalake.gold_zsdbil17_faturamento AS g
    ON g.chassis_serial_number = b.chassis_serial_number
WHERE g.chassis_serial_number IS NULL;

-- B2. Chassi novo na Gold que não estava na cópia.
SELECT COUNT(*) AS chassi_novo
FROM bp_datalake.gold_zsdbil17_faturamento AS g
LEFT JOIN bp_datalake.gold_zsdbil17_faturamento_bkp_20261123 AS b
    ON b.chassis_serial_number = g.chassis_serial_number
WHERE b.chassis_serial_number IS NULL;

-- B3. Mesmo chassi com algum valor diferente.
SELECT COUNT(*) AS linha_diferente
FROM bp_datalake.gold_zsdbil17_faturamento AS g
INNER JOIN bp_datalake.gold_zsdbil17_faturamento_bkp_20261123 AS b
    ON b.chassis_serial_number = g.chassis_serial_number
WHERE NOT (BINARY g.id_bronze <=> BINARY b.id_bronze)
        OR NOT (BINARY g.invoice_number <=> BINARY b.invoice_number)
        OR NOT (BINARY g.issuance_date <=> BINARY b.issuance_date)
        OR NOT (BINARY g.material <=> BINARY b.material)
        OR NOT (BINARY g.model_simplified <=> BINARY b.model_simplified)
        OR NOT (BINARY g.description <=> BINARY b.description)
        OR NOT (BINARY g.descricao_do_produto <=> BINARY b.descricao_do_produto)
        OR NOT (BINARY g.descricao_da_cor <=> BINARY b.descricao_da_cor)
        OR NOT (BINARY g.manufacturing_year <=> BINARY b.manufacturing_year)
        OR NOT (BINARY g.model_year <=> BINARY b.model_year)
        OR NOT (BINARY g.total_amount <=> BINARY b.total_amount)
        OR NOT (BINARY g.store_name_crm <=> BINARY b.store_name_crm)
        OR NOT (BINARY g.store_code <=> BINARY b.store_code)
        OR NOT (BINARY g.dealer_group <=> BINARY b.dealer_group)
        OR NOT (BINARY g.brand_dealer <=> BINARY b.brand_dealer)
        OR NOT (BINARY g.byd_cnpj_number <=> BINARY b.byd_cnpj_number)
        OR NOT (BINARY g.sold_to_party_code <=> BINARY b.sold_to_party_code)
        OR NOT (BINARY g.sold_to_party_cnpj <=> BINARY b.sold_to_party_cnpj)
        OR NOT (BINARY g.sold_to_party_name <=> BINARY b.sold_to_party_name)
        OR NOT (BINARY g.sold_to_party_state <=> BINARY b.sold_to_party_state)
        OR NOT (BINARY g.ship_to_party_code <=> BINARY b.ship_to_party_code)
        OR NOT (BINARY g.ship_to_party_cnpj <=> BINARY b.ship_to_party_cnpj)
        OR NOT (BINARY g.ship_to_party_name <=> BINARY b.ship_to_party_name)
        OR NOT (BINARY g.ship_to_party_state <=> BINARY b.ship_to_party_state)
        OR NOT (BINARY g.payment_condition <=> BINARY b.payment_condition)
        OR NOT (BINARY g.chave_de_acesso <=> BINARY b.chave_de_acesso)
        OR NOT (BINARY g.ncm <=> BINARY b.ncm)
        OR NOT (BINARY g.cfop <=> BINARY b.cfop)
        OR NOT (BINARY g.plant_code <=> BINARY b.plant_code)
        OR NOT (BINARY g.plant_description <=> BINARY b.plant_description)
        OR NOT (BINARY g.company_code <=> BINARY b.company_code)
        OR NOT (BINARY g.sales_order_type <=> BINARY b.sales_order_type)
        OR NOT (BINARY g.division <=> BINARY b.division)
        OR NOT (BINARY g.division_description <=> BINARY b.division_description)
        OR NOT (BINARY g.sap_document <=> BINARY b.sap_document)
        OR NOT (BINARY g.sales_order_number <=> BINARY b.sales_order_number)
        OR NOT (BINARY g.billing_number_vf01 <=> BINARY b.billing_number_vf01)
        OR NOT (BINARY g.delivery_note_number_picking <=> BINARY b.delivery_note_number_picking)
        OR NOT (BINARY g.iva <=> BINARY b.iva)
        OR NOT (BINARY g.dir_fiscal_icms <=> BINARY b.dir_fiscal_icms)
        OR NOT (BINARY g.dir_fiscal_ipi <=> BINARY b.dir_fiscal_ipi)
        OR NOT (BINARY g.dir_fiscal_iss <=> BINARY b.dir_fiscal_iss)
        OR NOT (BINARY g.dir_fiscal_cofins <=> BINARY b.dir_fiscal_cofins)
        OR NOT (BINARY g.dir_fiscal_pis <=> BINARY b.dir_fiscal_pis)
        OR NOT (BINARY g.payment_condition_description_dim <=> BINARY b.payment_condition_description_dim)
        OR NOT (BINARY g.origem_chassi <=> BINARY b.origem_chassi)
        OR NOT (BINARY g.invoice_series <=> BINARY b.invoice_series)
        OR NOT (BINARY g.proc_time <=> BINARY b.proc_time)
        OR NOT (BINARY g.no_do_motor <=> BINARY b.no_do_motor)
        OR NOT (BINARY g.codigo_da_cor <=> BINARY b.codigo_da_cor)
        OR NOT (BINARY g.potencia_motor <=> BINARY b.potencia_motor)
        OR NOT (BINARY g.cap_trac_max <=> BINARY b.cap_trac_max)
        OR NOT (BINARY g.cilindradas_cc <=> BINARY b.cilindradas_cc)
        OR NOT (BINARY g.distancia_entre_eixo <=> BINARY b.distancia_entre_eixo)
        OR NOT (BINARY g.peso_liquido_ton <=> BINARY b.peso_liquido_ton)
        OR NOT (BINARY g.peso_bruto_ton <=> BINARY b.peso_bruto_ton)
        OR NOT (BINARY g.tipo_de_veiculo <=> BINARY b.tipo_de_veiculo)
        OR NOT (BINARY g.especie_do_veiculo <=> BINARY b.especie_do_veiculo)
        OR NOT (BINARY g.tipo_do_combustivel <=> BINARY b.tipo_do_combustivel)
        OR NOT (BINARY g.tipo_de_pintura <=> BINARY b.tipo_de_pintura)
        OR NOT (BINARY g.condicao_do_veiculo <=> BINARY b.condicao_do_veiculo)
        OR NOT (BINARY g.cap_ocup_max <=> BINARY b.cap_ocup_max)
        OR NOT (BINARY g.vin_condition <=> BINARY b.vin_condition)
        OR NOT (BINARY g.code_brand_mode <=> BINARY b.code_brand_mode)
        OR NOT (BINARY g.item_category <=> BINARY b.item_category)
        OR NOT (BINARY g.order_no <=> BINARY b.order_no)
        OR NOT (BINARY g.order_car_no <=> BINARY b.order_car_no)
        OR NOT (BINARY g.order_status <=> BINARY b.order_status)
        OR NOT (BINARY g.source_file <=> BINARY b.source_file)
        OR NOT (BINARY g.dt_carga_silver <=> BINARY b.dt_carga_silver)
        OR NOT (BINARY g.record_source <=> BINARY b.record_source);

-- B4. Se B3 > 0: quais colunas diferem (amostra de 20 chassis).
--     Troque a coluna no SELECT conforme o caso.
-- SELECT g.chassis_serial_number, g.record_source,
--        b.model_simplified AS antes, g.model_simplified AS depois
-- FROM bp_datalake.gold_zsdbil17_faturamento AS g
-- INNER JOIN bp_datalake.gold_zsdbil17_faturamento_bkp_20261123 AS b
--     ON b.chassis_serial_number = g.chassis_serial_number
-- WHERE NOT (BINARY g.model_simplified <=> BINARY b.model_simplified)
-- LIMIT 20;


/*
============================================================
PARTE C - TEMPO DAS ETAPAS DA ÚLTIMA PIPELINE
============================================================
As 5 etapas sem log próprio aparecem com
audit_details.logged_by = 'sp_process_zsdbil17_pipeline'.
*/

SELECT
    l.procedure_name,
    l.execution_status,
    l.started_at,
    l.execution_duration_seconds,
    JSON_UNQUOTE(JSON_EXTRACT(l.audit_details, '$.logged_by')) AS logged_by
FROM bp_datalake.etl_execution_log AS l
INNER JOIN (
    SELECT started_at, finished_at
    FROM bp_datalake.etl_execution_log
    WHERE procedure_name = 'sp_process_zsdbil17_pipeline'
    ORDER BY id_execution DESC
    LIMIT 1
) AS p
    ON l.started_at BETWEEN p.started_at AND COALESCE(p.finished_at, NOW(6))
ORDER BY l.started_at, l.id_execution;


/*
============================================================
PARTE D - LIMPEZA DA CÓPIA (DEPOIS DE ALGUNS DIAS)
============================================================
Só com confirmação do Bruno.
*/

-- DROP TABLE bp_datalake.gold_zsdbil17_faturamento_bkp_20261123;
