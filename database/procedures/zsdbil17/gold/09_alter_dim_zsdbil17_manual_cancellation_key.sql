-- ============================================================
-- ZSDBIL17 - GOLD
-- 09 - CHAVE DO CANCELAMENTO MANUAL: CHASSI + NF + DATA + PLANTA
-- ============================================================
-- Objetivo:
-- Levar a tabela criada pela primeira versão do 07 (chave
-- chassi + NF) para a chave chassi + NF + data de emissão +
-- planta (ADR-004 do app cancellations).
--
-- Quando rodar:
-- UMA vez, só em ambiente onde a tabela já existia antes desta
-- mudança (produção, 06/11/2026). Instalação nova: o 07 atual já
-- cria a tabela com a chave nova; não rode este arquivo.
--
-- Cuidados:
-- 1. plant_code entra como NOT NULL sem valor padrão. Funciona
--    porque a tabela estava vazia na implantação (0 registros em
--    06/11/2026). Com registros, preencha a planta pela Silver
--    antes de tornar a coluna NOT NULL.
-- 2. Não é idempotente: rodar de novo falha em "Duplicate column"
--    sem alterar nada.
-- 3. Rodar com a pipeline Z17 parada; depois recriar a procedure
--    08, que passa a comparar os quatro campos.
-- ============================================================

ALTER TABLE bp_datalake.dim_zsdbil17_manual_cancellation
    ADD COLUMN plant_code VARCHAR(10) NOT NULL AFTER invoice_number,
    DROP INDEX uk_manual_cancellation_chassis_invoice,
    ADD UNIQUE KEY uk_manual_cancellation_invoice_key (
        chassis_serial_number,
        invoice_number,
        original_issuance_date,
        plant_code
    ),
    ADD CONSTRAINT chk_manual_cancellation_plant
        CHECK (TRIM(plant_code) <> '');

ALTER TABLE bp_datalake.dim_zsdbil17_manual_cancellation_audit_history
    ADD COLUMN original_issuance_date DATE NULL AFTER invoice_number,
    ADD COLUMN plant_code VARCHAR(10) NULL AFTER original_issuance_date;
