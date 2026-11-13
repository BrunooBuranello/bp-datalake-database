-- ============================================================
-- ZSDBIL17 - GOLD
-- 11 - REMESSA (delivery_note_number_picking) NA GOLD
-- ============================================================
-- Objetivo:
-- Disponibilizar na Gold o número da remessa do SAP ("Delivery
-- note number (Picking)" da Z17), que hoje existe só na Bronze e
-- na Silver. Pedido do Bruno em 13/11/2026 para o rastreamento do
-- veículo (NF -> remessa).
--
-- Quando rodar:
-- UMA vez, em ambiente onde a Gold já existia (produção).
-- Instalação nova: o 01 atual já cria a coluna.
--
-- Cuidados:
-- 1. Coluna NULL, sem valor padrão: ADD COLUMN é instantâneo e não
--    afeta consumidores (nenhum usa SELECT * na Gold).
-- 2. Depois do ALTER, recriar a procedure 02 (sp_gold_z17_load_base),
--    que passa a copiar a coluna. Antes de recriar a 02, ela continua
--    funcionando (lista de colunas explícita).
-- 3. Legado 2024/2025 não tem remessa: fica NULL nessas linhas.
-- 4. Tamanho: o maior valor na Silver em 13/11/2026 tinha 10
--    caracteres; VARCHAR(20) dá folga.
-- 5. Não é idempotente: rodar de novo falha em "Duplicate column".
-- ============================================================

ALTER TABLE bp_datalake.gold_zsdbil17_faturamento
    ADD COLUMN delivery_note_number_picking VARCHAR(20) NULL
        COMMENT 'Número da remessa (delivery) do SAP, copiado da Silver'
        AFTER billing_number_vf01;


-- ------------------------------------------------------------
-- Backfill opcional (evita esperar a próxima pipeline). A Gold
-- guarda o id_bronze da linha da Silver que a originou. Não chame
-- a sp_gold_z17_load_base sozinha para isso: ela recria a Gold sem
-- os enriquecimentos dos passos seguintes da pipeline.
-- ------------------------------------------------------------

UPDATE bp_datalake.gold_zsdbil17_faturamento AS g
INNER JOIN bp_datalake.silver_zsdbil17_outbound_movements AS s
    ON s.id_bronze = g.id_bronze
SET g.delivery_note_number_picking =
        LEFT(NULLIF(TRIM(s.delivery_note_number_picking), ''), 20)
WHERE g.record_source = 'ZSDBIL17_CURRENT';
