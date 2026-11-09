-- ============================================================
-- ZSDBIL17 - GOLD
-- 10 - HORÁRIO DA NF (proc_time) NA GOLD
-- ============================================================
-- Objetivo:
-- Disponibilizar na Gold o horário de processamento da NF no SAP
-- (coluna "first time" da Z17), que hoje existe só na Bronze e na
-- Silver. A Liberação de Veículos lê apenas a Gold e usa
-- issuance_date + proc_time para ordenar os faturamentos do mesmo
-- dia no consumo de crédito (FIFO).
--
-- Quando rodar:
-- UMA vez, em ambiente onde a Gold já existia (produção,
-- 09/11/2026). Instalação nova: o 01 atual já cria a coluna.
--
-- Cuidados:
-- 1. Coluna NULL, sem valor padrão: o ALTER é instantâneo e não
--    afeta consumidores (nenhum usa SELECT * na Gold).
-- 2. Depois do ALTER, recriar a procedure 02
--    (sp_gold_z17_load_base), que passa a copiar s.proc_time.
--    Até a próxima execução da pipeline a coluna fica NULL.
-- 3. O legado 2024/2025 (sp_gold_z17_append_legacy_2024_2025)
--    não tem horário: continua NULL nessas linhas.
-- 4. Não é idempotente: rodar de novo falha em "Duplicate column"
--    sem alterar nada.
-- ============================================================

ALTER TABLE bp_datalake.gold_zsdbil17_faturamento
    ADD COLUMN proc_time TIME NULL
        COMMENT 'Horário de processamento da NF no SAP (first time da Z17); desempate do FIFO da Liberação'
        AFTER invoice_series;


-- ------------------------------------------------------------
-- Backfill opcional (evita esperar a próxima pipeline).
-- A Gold guarda o id_bronze da linha da Silver que a originou,
-- então o horário é copiado da mesma linha. Não chame a
-- sp_gold_z17_load_base sozinha para isso: ela recria a Gold sem
-- os enriquecimentos dos passos seguintes da pipeline.
-- ------------------------------------------------------------

UPDATE bp_datalake.gold_zsdbil17_faturamento AS g
INNER JOIN bp_datalake.silver_zsdbil17_outbound_movements AS s
    ON s.id_bronze = g.id_bronze
SET g.proc_time = s.proc_time
WHERE g.record_source = 'ZSDBIL17_CURRENT';
