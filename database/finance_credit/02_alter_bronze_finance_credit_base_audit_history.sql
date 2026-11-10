-- ============================================================
-- ALTER: bp_datalake.bronze_finance_credit_base_audit_history
-- CAMADA: Bronze (auditoria, append-only)
--
-- OBJETIVO DO ALTER:
-- A auditoria criada em 09/11/2026 (vehicle_release/05) só
-- guardava CNPJ e valor antigos/novos. Para ser auditável de
-- verdade, cada diferença passa a guardar:
--   - load_run_id: em qual execução a diferença foi detectada;
--   - row_key: a linha da BASE (mesma chave da tabela principal);
--   - changed_columns: quais colunas mudaram (CHANGED);
--   - old_values / new_values: a linha inteira antes e depois (JSON).
--
-- Também deixa chassi e NF aceitarem o valor bruto da planilha:
-- a BASE tem linhas com NF não numérica ou chassi fora do padrão,
-- e a auditoria não pode falhar por causa delas.
--
-- ROLLBACK:
-- DROP COLUMN das colunas novas; MODIFY de volta para
-- VARCHAR(17)/VARCHAR(9) NOT NULL só se não houver linha fora do
-- padrão gravada.
-- ============================================================

ALTER TABLE bp_datalake.bronze_finance_credit_base_audit_history

    MODIFY COLUMN chassis VARCHAR(64) NULL,
    MODIFY COLUMN invoice_number VARCHAR(64) NULL,

    ADD COLUMN load_run_id BIGINT NULL
        COMMENT 'Execução da carga que detectou a diferença'
        AFTER id,
    ADD COLUMN row_key CHAR(64) NULL
        COMMENT 'SHA-256 de chassi + NF + data + ocorrência'
        AFTER load_run_id,
    ADD COLUMN changed_columns TEXT NULL
        COMMENT 'Colunas alteradas (CHANGED), separadas por vírgula'
        AFTER change_type,
    ADD COLUMN old_values JSON NULL
        COMMENT 'Linha antes da mudança (CHANGED, REMOVED)'
        AFTER new_invoice_amount,
    ADD COLUMN new_values JSON NULL
        COMMENT 'Linha depois da mudança (INSERTED, CHANGED)'
        AFTER old_values,

    ADD INDEX idx_finance_credit_audit_run (load_run_id),
    ADD INDEX idx_finance_credit_audit_row_key (row_key);
