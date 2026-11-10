-- ============================================================
-- ALTER: bp_datalake.bronze_finance_credit_base
-- CAMADA: Bronze
--
-- ORIGEM:
-- Aba BASE da planilha de controle de crédito do Financeiro
-- ("CRÉDITO DEALER ..._new distribution.xlsx", na rede, com senha).
-- Carga automática pela integração finance_credit do BYD Sales
-- Operation (data_integrations, ADR-004), de hora em hora.
--
-- OBJETIVO DO ALTER:
-- A tabela criada em 09/11/2026 (vehicle_release/04) tinha só a
-- chave e o valor. A carga passa a guardar a linha inteira da aba
-- BASE (fiel à planilha) e as colunas de controle do rastreio:
--   - row_key: SHA-256 da chave chassi + NF + data + ocorrência
--     (a BASE tem chaves repetidas; a ocorrência as separa);
--   - row_hash: SHA-256 do conteúdo, para saber se a linha mudou;
--   - load_run_id: execução (bronze_finance_credit_load_run_audit_history)
--     que gravou ou alterou a linha por último.
--
-- ESTRATÉGIA DE CARGA:
-- Diferencial: só entram as linhas novas, só saem as removidas e
-- só são atualizadas as que mudaram (row_hash diferente). Cada
-- diferença vai para bronze_finance_credit_base_audit_history.
-- Tudo numa transação; se a carga tirar mais de 20% das linhas,
-- nada é gravado (execução BLOCKED).
--
-- DECISÕES:
-- - Colunas da planilha em TEXT (padrão Bronze de arquivo manual):
--   a inconsistência da origem não pode impedir a carga. A
--   normalização (NF 9 dígitos, data) fica na procedure que lê.
-- - issuance_date gravada como texto ISO (AAAA-MM-DD) quando a
--   célula é data; a procedure da Liberação já aceita esse formato.
-- - invoice_amount (já existente) recebe a coluna F "a pagar".
-- - UNIQUE em row_key: a carga garante uma linha por chave +
--   ocorrência (exceção à regra "Bronze sem UNIQUE", justificada).
--
-- ROLLBACK:
-- ALTER TABLE ... DROP COLUMN das colunas abaixo e DROP INDEX
-- uk_bronze_finance_credit_base_row_key (a tabela estava vazia
-- antes desta mudança).
-- ============================================================

ALTER TABLE bp_datalake.bronze_finance_credit_base

    -- ========================================================
    -- COLUNAS DA PLANILHA QUE FALTAVAM (fiéis à origem)
    -- ========================================================

    ADD COLUMN chassis_raw TEXT NULL
        COMMENT 'Coluna A CHASSI (chassis = coluna B CHASSI AJUSTADO)'
        AFTER chassis,
    ADD COLUMN customer_name TEXT NULL
        COMMENT 'Coluna C CLIENTE'
        AFTER customer_cnpj,
    ADD COLUMN amount_received TEXT NULL
        COMMENT 'Coluna G Recebido'
        AFTER invoice_amount,
    ADD COLUMN due_date TEXT NULL
        COMMENT 'Coluna I Data Vencimento (AAAA-MM-DD quando data)'
        AFTER amount_received,
    ADD COLUMN received_amount_check TEXT NULL
        COMMENT 'Coluna J Conf vlr recebido'
        AFTER due_date,
    ADD COLUMN chassis_invoice_key TEXT NULL
        COMMENT 'Coluna K CHASSI + NF (chave usada pelo Financeiro)'
        AFTER received_amount_check,
    ADD COLUMN cancellation_check TEXT NULL
        COMMENT 'Coluna L Check cancelado ("-" ou referência da NF cancelada)'
        AFTER chassis_invoice_key,

    -- ========================================================
    -- CONTROLE DO RASTREIO
    -- ========================================================

    ADD COLUMN source_row_number INT NULL
        COMMENT 'Linha da aba BASE na última carga'
        AFTER cancellation_check,
    ADD COLUMN row_key CHAR(64) NULL
        COMMENT 'SHA-256 de chassi + NF + data + ocorrência'
        AFTER source_row_number,
    ADD COLUMN row_hash CHAR(64) NULL
        COMMENT 'SHA-256 do conteúdo da linha'
        AFTER row_key,
    ADD COLUMN load_run_id BIGINT NULL
        COMMENT 'Execução que gravou/alterou a linha por último'
        AFTER row_hash,

    ADD UNIQUE INDEX uk_bronze_finance_credit_base_row_key (row_key);
