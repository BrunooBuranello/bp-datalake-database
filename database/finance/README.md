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
| `06_sp_load_finance_credit_opening_balance.sql` | `sp_load_finance_credit_opening_balance` | Carga ÚNICA do saldo inicial (chaves da aba CARS = NF paga 100%) |
| `07_create_bronze_finance_credit_cars.sql` | `bronze_finance_credit_cars` | Foto da aba CARS, gravada por `manage.py load_finance_credit_cars` |
| `../procedures/zsdbil17/pipeline/sp_process_zsdbil17_pipeline.sql` | pipeline Z17 | Chama o sync no passo 18.2 |

**Ordem do deploy:** 01 → 02 → 03 → 04 → 05 → 07 → 06 →
`CALL sp_sync_gold_finance_credit_receivable('MANUAL', '<usuário>', @run_id);`
→ pipeline (passo 18.2). A pipeline só pode ser atualizada **depois** que a
procedure existir; senão a Z17 falha.

O saldo inicial roda **na virada**, combinada com o Financeiro: o Financeiro
para de lançar na planilha → `python manage.py load_finance_credit_cars --user
<usuário>` (foto da aba CARS) → `CALL sp_load_finance_credit_opening_balance('<usuário>')`.
Cada chassi + NF da CARS com exatamente 1 NF no AR / Crédito vira um
lançamento com o valor da NF e a PAYMENT DATE quando a chave tem uma data só;
nunca dois saldos iniciais na mesma NF (finance ADR-008).

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

-- Chaves da aba CARS (foto) sem NF no AR / Crédito
-- (ficaram fora do saldo inicial)
SELECT c.chassis_serial_number, c.invoice_number,
       COUNT(*) AS cars_rows, MIN(c.payment_date) AS first_payment_date
FROM bp_datalake.bronze_finance_credit_cars AS c
LEFT JOIN bp_datalake.gold_finance_credit_receivable AS g
    ON  g.chassis_serial_number = c.chassis_serial_number
    AND g.invoice_number = c.invoice_number
WHERE c.key_valid = 'YES'
  AND g.id IS NULL
GROUP BY c.chassis_serial_number, c.invoice_number;
```

## Rollback

- Pipeline: remover o passo 18.2 e recriar a `sp_process_zsdbil17_pipeline`.
- Tabelas podem ficar (não são lidas por mais ninguém). Se for preciso apagar
  o saldo inicial para recarregar: `DELETE` dos lançamentos
  `entry_source = 'LEGACY_SPREADSHEET'` e da auditoria `OPENING_BALANCE` e
  recalcular `received_amount` das NFs afetadas pela soma dos lançamentos
  ativos que sobraram (consulta de conferência acima) — só com aprovação do
  Bruno.
