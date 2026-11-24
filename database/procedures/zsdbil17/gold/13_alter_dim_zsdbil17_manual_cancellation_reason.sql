-- ============================================================
-- ZSDBIL17 - GOLD
-- 13 - MOTIVO DA DESATIVAÇÃO DO CANCELAMENTO MANUAL
-- ============================================================
-- Objetivo:
-- Guardar o motivo informado por quem desativa um cancelamento
-- manual (ADR-007 do app cancellations). Quem e quando já eram
-- gravados (deactivated_by / deactivated_at).
--
-- Colunas:
-- - dim_zsdbil17_manual_cancellation.deactivation_reason:
--   motivo da desativação atual. Volta a NULL quando a mesma NF
--   é registrada de novo (reativação).
-- - dim_zsdbil17_manual_cancellation_audit_history.reason:
--   motivo gravado na linha DEACTIVATE da auditoria; o histórico
--   continua com o motivo mesmo depois de uma reativação.
--
-- Quando rodar:
-- UMA vez, em ambiente onde as tabelas já existiam (produção).
-- Instalação nova: o 07 atual já cria as duas colunas; não rode
-- este arquivo.
--
-- Cuidados:
-- 1. Rodar ANTES de publicar o app: o app novo lê e grava estas
--    colunas e a tela falharia sem elas.
-- 2. Coluna NULL no fim da tabela: ALGORITHM=INSTANT no MySQL 8
--    (sem copiar a tabela). As linhas atuais ficam com NULL, inclusive
--    as já desativadas (não havia motivo antes desta mudança).
-- 3. Não é idempotente: rodar de novo falha em "Duplicate column"
--    sem alterar nada.
-- 4. Conferir o processlist antes: DDL espera qualquer consulta
--    aberta nessas tabelas (metadata lock).
-- 5. A procedure 08 não usa estas colunas: não precisa recriar.
-- ============================================================

ALTER TABLE bp_datalake.dim_zsdbil17_manual_cancellation
    ADD COLUMN deactivation_reason VARCHAR(500) NULL
        COMMENT 'Motivo informado ao desativar (ADR-007 do app cancellations)',
    ALGORITHM = INSTANT;

ALTER TABLE bp_datalake.dim_zsdbil17_manual_cancellation_audit_history
    ADD COLUMN reason VARCHAR(500) NULL
        COMMENT 'Motivo da desativação (linhas DEACTIVATE)',
    ALGORITHM = INSTANT;
