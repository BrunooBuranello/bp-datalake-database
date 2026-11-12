# Financeiro › AR / Crédito — SQL

Tabelas e procedures do AR / Crédito do app `finance` do BYD Sales Operation
(ADR-001 e ADR-002 de `finance/docs/DECISIONS.md`). Substitui a aba BASE, a
aba CARS e a aba PIVOT da planilha "CRÉDITO DEALER ..._new distribution" do
Financeiro.

| Aba da planilha | Vira |
|---|---|
| BASE | `gold_finance_credit_receivable` (gerada da Gold Z17) |
| CARS (input de recebido) | `bronze_finance_credit_receipt` (tela do app) |
| PIVOT | consulta agrupada por CNPJ / raiz do CNPJ (tela + export) |

## Arquivos (ordem de implantação)

| Arquivo | Objeto | Função |
|---|---|---|
| `01_create_gold_finance_credit_receivable.sql` | `gold_finance_credit_receivable` | Uma linha por NF (chassi + NF + data + planta): cliente, valor, vencimento, recebido, saldo |
| `02_create_gold_finance_credit_receivable_run_audit_history.sql` | `..._run_audit_history` | Uma linha por execução do sync |
| `03_create_bronze_finance_credit_receipt.sql` | `bronze_finance_credit_receipt` | Lançamentos de recebimento (livro-razão; estorno em vez de apagar) |
| `04_create_bronze_finance_credit_receipt_audit_history.sql` | `..._receipt_audit_history` | Quem lançou / estornou, quando, quanto |
| `05_sp_sync_gold_finance_credit_receivable.sql` | `sp_sync_gold_finance_credit_receivable` | Upsert a partir da Gold (passo 18.2 da pipeline Z17) |
| `06_sp_load_finance_credit_opening_balance.sql` | `sp_load_finance_credit_opening_balance` | Carga ÚNICA do saldo inicial ("Recebido" da planilha) |
| `../procedures/zsdbil17/pipeline/sp_process_zsdbil17_pipeline.sql` | pipeline Z17 | Chama o sync no passo 18.2 |

**Ordem do deploy:** 01 → 02 → 03 → 04 → 05 → 06 →
`CALL sp_sync_gold_finance_credit_receivable('MANUAL', '<usuário>', @run_id);`
→ pipeline (passo 18.2). A pipeline só pode ser atualizada **depois** que a
procedure existir; senão a Z17 falha.

O saldo inicial (`CALL sp_load_finance_credit_opening_balance('<usuário>')`)
roda **na virada**, combinada com o Financeiro: depois da última carga da
planilha e antes do primeiro lançamento pelo app. Casa chassi + NF + data e,
quando a data da planilha está errada, chassi + NF com quatro travas (NF
única, mesmo valor de NF, uma linha da planilha por NF, NF não casada pela
data); nunca grava dois saldos iniciais na mesma NF (finance ADR-007).
Ensaio de 12/11/2026: 354.048 pela data + 138 por chassi + NF; 25.874 sem
NF.

## Regras

- **Escopo:** todo o histórico da Gold. B1 Revenda, B2 Test Drive, B3 PCD,
  B4 Táxi, B5 Venda Direta. No legado 2024/2025 (outros códigos de division),
  entra pela descrição RESALE / TEST DRIVE / DIRECT SALE.
- **Cliente:** Revenda e Test Drive → sold-to; demais → ship-to.
- **Vencimento:** emissão + dias da `dim_cond_pagamento`
  (`desc_prazo_pgto_atribuicao_bp` numérico ou "dentro de N dias" do texto
  SAP; "pagamento imediato" = 0). Sem dias → `due_date` NULL.
- **Chave antiga** (`legacy_key`): `CHASSI-NF`, NF sem zeros à esquerda, igual
  à coluna "CHASSI + NF" da planilha. Só para digitação; se apontar para mais
  de uma NF, o app recusa e pede a chave completa.
- **Recebido:** `received_amount` = soma dos lançamentos ativos, atualizada na
  mesma transação do lançamento/estorno. `open_amount` e `payment_status`
  (OPEN, PARTIAL, PAID, OVERPAID) são colunas geradas.
- NF que sai da Gold fica com `in_gold = 'NO'` (não é apagada).

## Consultas úteis

```sql
-- Últimas execuções do sync
SELECT run_id, trigger_source, started_at, run_status, gold_rows_read,
       nfs_inserted, nfs_removed_from_gold, nfs_without_due_date, error_message
FROM bp_datalake.gold_finance_credit_receivable_run_audit_history
ORDER BY run_id DESC
LIMIT 20;

-- Conferência: received_amount bate com a soma dos lançamentos ativos?
-- (esperado: zero linhas)
SELECT g.id, g.received_amount, COALESCE(SUM(r.received_amount), 0) AS ledger_sum
FROM bp_datalake.gold_finance_credit_receivable AS g
LEFT JOIN bp_datalake.bronze_finance_credit_receipt AS r
    ON  r.chassis_serial_number = g.chassis_serial_number
    AND r.invoice_number = g.invoice_number
    AND r.issuance_date = g.issuance_date
    AND r.plant_code = g.plant_code
    AND r.active = 1
GROUP BY g.id, g.received_amount
HAVING g.received_amount <> ledger_sum;

-- Linhas da BASE da planilha com recebido e sem NF no AR / Crédito
-- (ficaram fora do saldo inicial)
SELECT b.chassis, b.invoice_number, b.issuance_date, b.amount_received
FROM bp_datalake.bronze_finance_credit_base AS b
LEFT JOIN bp_datalake.gold_finance_credit_receivable AS g
    ON  g.chassis_serial_number = b.chassis
    AND g.invoice_number = LPAD(TRIM(b.invoice_number), 9, '0')
    AND g.issuance_date = DATE(LEFT(b.issuance_date, 10))
WHERE g.id IS NULL
  AND CAST(REPLACE(b.amount_received, ',', '.') AS DECIMAL(15,2)) <> 0;
```

## Rollback

- Pipeline: remover o passo 18.2 e recriar a `sp_process_zsdbil17_pipeline`.
- Tabelas podem ficar (não são lidas por mais ninguém). Se for preciso apagar
  o saldo inicial para recarregar: `DELETE` dos lançamentos
  `entry_source = 'LEGACY_SPREADSHEET'` e da auditoria `OPENING_BALANCE` e
  recalcular `received_amount` das NFs afetadas pela soma dos lançamentos
  ativos que sobraram (consulta de conferência acima) — só com aprovação do
  Bruno.
