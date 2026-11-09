# Liberação de Veículos — SQL

Estruturas e procedure da Liberação de Veículos (app `vehicle_release` do BYD
Sales Operation). Substitui o processo em Google Sheets + `Liberação.xlsm`.

## Arquivos (ordem de implantação)

| Arquivo | Objeto | Função |
|---|---|---|
| `01_create_bronze_vehicle_release.sql` | `bronze_vehicle_release` | Foto atual: status de cada NF (chassi + NF + data + planta) |
| `02_create_bronze_vehicle_release_audit_history.sql` | `bronze_vehicle_release_audit_history` | Cada mudança de status (append-only); base do aging por status |
| `03_create_bronze_vehicle_release_run_audit_history.sql` | `bronze_vehicle_release_run_audit_history` | Uma linha por execução: quem, quando, origem, totais, frescor do CRM |
| `04_create_bronze_finance_credit_base.sql` | `bronze_finance_credit_base` | BASE do controle de crédito do Financeiro (vazia até o script de carga) |
| `05_create_bronze_finance_credit_base_audit_history.sql` | `bronze_finance_credit_base_audit_history` | Diferenças entre cargas da BASE (rotina a definir) |
| `06_sp_sync_bronze_vehicle_release.sql` | `sp_sync_bronze_vehicle_release` | Monta a foto, grava eventos e a execução |

Chamada no fim da `sp_process_zsdbil17_pipeline` (passo 18.1, depois da DEMO)
e pelo botão do app:

```sql
CALL bp_datalake.sp_sync_bronze_vehicle_release('BUTTON', '<usuario>', @run_id);
SELECT * FROM bp_datalake.bronze_vehicle_release_run_audit_history WHERE run_id = @run_id;
```

## Escopo

| Grupo | Tipos de venda (Gold `division`) | Situação |
|---|---|---|
| Grupo 1 | B1 Resale, B2 Test Drive, locadoras (lista de CNPJs do app) | Fase 1 (B1/B2 já; locadoras quando a lista existir) |
| Grupo 2 | B5 Direct Sale, **B3 PCD, B4 Táxi** (mesmo grupo da VD) | Fase 2 |
| Fora | Demo / Showroom, Asset / Seguradora | Não liberado por esta consulta: consultar o time BP Auto |

Corte da fase 1: NFs emitidas a partir de `2026-10-01` (`c_start_issuance_date`).

## Regras do Grupo 1 (ordem do status)

1. **Já liberado** → `RELEASED`: chave consta como `RELEASED` no histórico
   manual (`bronze_chassis_released_to_logistics`) ou o pedido do CRM já passou
   da expedição (`To Be Received` / `Completed`).
2. **Prazo > 30 dias** → senão `REVIEW_PAYMENT_TERM`. Dias pela
   `dim_cond_pagamento.desc_prazo_pgto_atribuicao_bp`; quando ela traz `-`
   (98% das NFs de Revenda em 09/11/2026), o número sai do texto SAP
   "dentro de **N** dias". Sem número → revisão.
3. **BASE do financeiro** (chassi + NF + data) → senão `WAITING_FINANCE`.
4. **CRM** com exatamente 1 pedido e `order_sub_status = 'To Be Shipped'`
   → senão `WAITING_CRM`.
5. Tudo ok → `READY_TO_RELEASE`.

`release_status_reason` lista todas as regras que falharam.

## ⚠️ Chave escolhida para o CRM: chassi + NF + data

> **Aviso:** o pedido do CRM (`dwd_sal_slm_base_order_details`) é encontrado
> por **chassi + NF + data do faturamento**, nunca só pelo chassi. Um chassi
> pode ter mais de um pedido no CRM (pedido refeito, troca, devolução).

Medição de 09/11/2026 (carga do CRM das 17:30), Revenda/Test Drive emitidas
desde 01/10/2026:

| Chave | NFs encontradas | Linhas do CRM |
|---|---|---|
| só chassi | 20.721 | 21.012 (pedidos repetidos) |
| chassi + NF | 20.709 | 20.709 |
| **chassi + NF + data** | **20.709 de 20.747 (99,8%)** | **20.709: exatamente 1 pedido por NF** |

Consulta de referência:

```sql
SELECT
    COUNT(DISTINCT g.id_bronze) AS nfs,
    COUNT(DISTINCT CASE WHEN c.vin_code IS NOT NULL THEN g.id_bronze END) AS nfs_com_pedido,
    COUNT(c.vin_code) AS linhas_crm
FROM bp_datalake.gold_zsdbil17_faturamento AS g
LEFT JOIN bp_datalake.dwd_sal_slm_base_order_details AS c
    ON  c.vin_code = g.chassis_serial_number
    AND c.sap_nf_e_no = g.invoice_number
    AND DATE(c.invoice_date) = g.issuance_date
WHERE g.issuance_date >= '2026-10-01'
  AND g.division IN ('B1', 'B2');
```

Se `linhas_crm` ficar maior que `nfs_com_pedido`, a chave deixou de ser única:
a procedure marca essas NFs com `crm_match_count > 1` e manda para revisão.

## Cuidados de operação

- Botão recusado enquanto a pipeline Z17 está `RUNNING` (não lê a Gold no meio
  da atualização) e `GET_LOCK` impede duas execuções ao mesmo tempo.
- Erro: `ROLLBACK`, `run_status = ERROR`, sem `RESIGNAL` (a pipeline continua).
- `crm_is_fresh = NO` na execução: o CRM não foi carregado hoje; a liberação
  do dia não deve ser feita com ele.
- D+1 em dias úteis (feriados + fins de semana) é calculado no app, com o
  calendário de `demo_notifications/domain/send_calendar.py`.
