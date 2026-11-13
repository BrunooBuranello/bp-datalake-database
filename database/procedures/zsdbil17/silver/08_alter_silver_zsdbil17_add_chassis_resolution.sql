-- ============================================================
-- ZSDBIL17 - SILVER
-- 08 - COLUNAS DA REGRA DE CHASSI (chassis_rule / chassis_source)
-- ============================================================
-- Objetivo (ADR-016 do sap_service):
-- Registrar, em cada linha da Silver, qual regra decidiu o chassi
-- e de qual coluna do SAP ele veio. A Bronze continua igual à
-- origem; só a Silver passa a ter o chassi resolvido.
--
-- chassis_rule   (uma por linha, gravada por
--                 sp_silver_z17_chassis_resolution):
--   SAP_CHASSIS                    chassi veio na coluna do SAP
--   CHASSI_DO_VEICULO              carro sem chassi; VIN de "Chassi do Veiculo"
--   CUSTOMER_REFERENCE             carro sem chassi; VIN de "Customer Reference"
--   TAX_COMPLEMENT                 NF só de imposto (sem ordem, sem VF01,
--                                  valor do item 0): chassi não se aplica
--   NOT_CAR_BUS_TRUCK / NOT_CAR_PART / NOT_CAR_OTHER
--                                  material que não é carro
--   CAR_NOT_SALE                   carro fora do CFOP de venda (entradas,
--                                  transferências, retornos)
--   NO_CHASSIS_EXPECTED            demais linhas sem VIN, que não são carro
--   FALLBACK_*                     nenhuma regra resolveu: a linha também
--                                  vai para silver_zsdbil17_chassis_fallback
--
-- chassis_source (só quando chassis_serial_number ficou preenchido):
--   SAP, CHASSI_DO_VEICULO ou CUSTOMER_REFERENCE
--
-- Quando rodar:
-- UMA vez, antes de criar a procedure 10. Depois do ALTER todas as
-- linhas ficam com chassis_rule NULL e a primeira execução da
-- procedure classifica o histórico inteiro (~1,5 milhão de linhas).
--
-- Cuidados:
-- 1. Colunas NULL sem valor padrão: ADD COLUMN é instantâneo no
--    MySQL 8. O ADD INDEX é online, mas lê a tabela inteira; rodar
--    fora do horário da Z17 (fila SAP vazia).
-- 2. Não é idempotente: rodar de novo falha em "Duplicate column".
-- 3. A carga incremental (sp_silver_z17_load_base) apaga e recarrega
--    as datas da staging: as linhas recarregadas voltam com
--    chassis_rule NULL e são reclassificadas na mesma pipeline.
-- ============================================================

ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
    ADD COLUMN chassis_source VARCHAR(30) NULL
        COMMENT 'De onde veio o chassi: SAP, CHASSI_DO_VEICULO ou CUSTOMER_REFERENCE (ADR-016)'
        AFTER chassis_serial_number,
    ADD COLUMN chassis_rule VARCHAR(50) NULL
        COMMENT 'Regra que decidiu o chassi da linha; FALLBACK_* = sem regra (ADR-016)'
        AFTER chassis_source;

-- A procedure busca as linhas pendentes por chassis_rule (NULL ou
-- FALLBACK_*) a cada pipeline.
ALTER TABLE bp_datalake.silver_zsdbil17_outbound_movements
    ADD INDEX idx_sz17_chassis_rule (chassis_rule);
