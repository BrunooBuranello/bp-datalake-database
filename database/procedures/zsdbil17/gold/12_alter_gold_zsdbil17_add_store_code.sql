-- ============================================================
-- ZSDBIL17 - GOLD
-- 12 - CÓDIGO DA LOJA (store_code) NA GOLD
-- ============================================================
-- Objetivo:
-- Disponibilizar na Gold o código da loja do CRM
-- (bronze.mapping_dealer_expansion.store_code), junto com o
-- store_name_crm que o sp_gold_z17_enrich já grava. Pedido do Bruno
-- em 13/11/2026.
--
-- Quando rodar:
-- UMA vez, em ambiente onde a Gold já existia (produção).
-- Instalação nova: o 01 atual já cria a coluna.
--
-- Ordem:
-- 1. ESTE arquivo (ADD COLUMN, instantâneo no MySQL 8.0.29+).
-- 2. Recriar a procedure 04 (sp_gold_z17_enrich), que passa a
--    preencher a coluna. Antes disso a coluna fica NULL; nada quebra.
-- 3. Opcional: CALL bp_datalake.sp_gold_z17_enrich(); para preencher
--    sem esperar a próxima pipeline (só faz UPDATE nas colunas de
--    enriquecimento, não recria a Gold).
--
-- Cuidados:
-- 1. Coluna NULL, sem valor padrão: não afeta consumidores (nenhum
--    usa SELECT * na Gold).
-- 2. Legado 2024/2025 fica NULL (o enriquecimento de dealer só vale
--    para record_source = 'ZSDBIL17_CURRENT').
-- 3. Tamanho: o maior store_code no CRM em 13/11/2026 tinha 11
--    caracteres; VARCHAR(20) dá folga.
-- 4. Não é idempotente: rodar de novo falha em "Duplicate column".
-- 5. Antes de rodar, conferir o processlist: consulta longa aberta na
--    Gold segura metadata lock e faz o ALTER esperar.
-- ============================================================

ALTER TABLE bp_datalake.gold_zsdbil17_faturamento
    ADD COLUMN store_code VARCHAR(20) NULL
        COMMENT 'Código da loja no CRM (mapping_dealer_expansion.store_code)'
        AFTER store_name_crm;
