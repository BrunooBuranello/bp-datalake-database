# Planilha de crédito do Financeiro — SQL

Tabelas da carga automática da planilha "CRÉDITO DEALER ..._new
distribution.xlsx" do Financeiro, feita pela integração `finance_credit` do BYD
Sales Operation (ADR-004 de `data_integrations/docs/DECISIONS.md`). Substitui o
`Exportador_Credito.py` + a carga manual pela tela Data Ingestion.

## Arquivos (ordem de implantação)

| Arquivo | Objeto | Função |
|---|---|---|
| `01_alter_bronze_finance_credit_base.sql` | `bronze_finance_credit_base` | Guarda as 12 colunas da aba BASE + controle (`row_key`, `row_hash`, `load_run_id`) |
| `02_alter_bronze_finance_credit_base_audit_history.sql` | `bronze_finance_credit_base_audit_history` | Diferenças com colunas alteradas e linha antes/depois (JSON) |
| `03_create_bronze_finance_credit_load_run_audit_history.sql` | `bronze_finance_credit_load_run_audit_history` | Uma linha por execução: arquivo, SHA-256, contagens, status |

As tabelas originais estão em `../vehicle_release/04` e `05` (criadas vazias em
09/11/2026). `bronze_espelho_credito` (CARTA + EMBARQUE) já existia e não muda.

## Como a carga funciona

1. Lê o arquivo da rede uma vez (SHA-256) e descriptografa só em memória.
2. Arquivo igual ao da última carga com sucesso → `SKIPPED`.
3. Cabeçalho diferente / aba vazia / carga tirando mais de 20% da BASE →
   `BLOCKED` (nada gravado).
4. BASE diferencial + auditoria + espelho numa transação só → `SUCCESS`.

## Consultas úteis

```sql
-- Últimas execuções
SELECT run_id, started_at, run_status, source_file_modified_at,
       base_rows_read, base_rows_inserted, base_rows_changed, base_rows_removed,
       credit_rows_loaded, error_message
FROM bp_datalake.bronze_finance_credit_load_run_audit_history
ORDER BY run_id DESC
LIMIT 20;

-- O que mudou numa execução
SELECT change_type, chassis, invoice_number, issuance_date, changed_columns
FROM bp_datalake.bronze_finance_credit_base_audit_history
WHERE load_run_id = ?;
```
