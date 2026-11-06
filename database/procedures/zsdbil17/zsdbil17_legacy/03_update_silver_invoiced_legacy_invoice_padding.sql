-- ============================================================
-- INVOICED LEGACY 2024/2025 - SILVER
-- 03 - NF COM 9 DÍGITOS (CORREÇÃO ÚNICA)
-- ============================================================
-- Objetivo:
-- Deixar a NF da silver_invoiced_legacy_2024_2025 no mesmo
-- formato da Silver da Z17: 9 dígitos com zeros à esquerda
-- (regra "Chave de uma NF de veículo" no README). Na carga
-- seguinte da Z17, o append do legado leva o formato para a
-- gold_zsdbil17_faturamento (a Gold é remontada a cada carga).
--
-- Por que UPDATE e não rodar a 01 de novo:
-- A 01 apaga a Silver do legado e recarrega da Bronze. Se a
-- Bronze recebeu APPEND depois de 22/09/2026, o resultado
-- mudaria. A 01 já tem o LPAD para recargas futuras.
--
-- Conferido em 06/11/2026: 244.162 linhas, todas só números
-- com 1 a 9 dígitos; 0 chassis mudam de NF escolhida no
-- desempate do append (invoice_number DESC).
--
-- Cuidados:
-- 1. Rodar com a pipeline Z17 parada (o append lê esta tabela).
-- 2. Idempotente: rodar de novo não altera nada (só toca NF
--    com menos de 9 dígitos).
-- 3. Valor que não for só número não é alterado.
-- ============================================================

UPDATE bp_datalake.silver_invoiced_legacy_2024_2025
SET invoice_number = LPAD(TRIM(invoice_number), 9, '0')
WHERE TRIM(invoice_number) REGEXP '^[0-9]{1,8}$';
