# VA05 — ordens de venda e canal online/offline

Pedido do time CRM (27/11/2026): saber se cada pedido faturado nasceu
**online** (CRM) ou **offline** (criado à mão no SAP por usuário BYD) e
gerar um template para o time do CRM (China) corrigir o CRM.

## Fluxo

```text
SAP VA05 (data do documento, todas as colunas) -> CSV csv-LEAN-STANDARD
   │  app: TRUNCATE + INSERT
   ▼
stg_va05_sales_order                 foto da última execução (97 colunas TEXT)
   │  sp_stg_reconcile_va05_sales_order_bronze(início, fim)
   ▼
bronze_va05_sales_order              histórico sem repetir: 1 linha por item
   │  sp_silver_va05_sales_order_channel(início, fim)
   ▼
silver_va05_sales_order_channel      tipada + order_channel
```

## Regras

- **Grão:** item da ordem (`documento_de_vendas` + `item`). Medido em
  27/11/2026: 3.932 itens, 1.808 ordens, 0 repetições.
- **Sem linhas repetidas:** a VA05 roda de hora em hora sobre o mesmo
  período, como a Z17. O `reconciliation_hash` (MD5 de documento + item) é
  `UNIQUE` na Bronze; cada execução substitui o item pelo estado atual e
  preserva `first_seen_at`. Item que some de um período coberto vira
  `MISSING` (nunca é apagado).
- **Canal** (`order_channel`, pelo `criado_por`):

  | `criado_por` | Canal |
  |---|---|
  | `RFC_BRCRM` | `ONLINE_CRM` |
  | outro `RFC_*` (DMS, Mall, BSS) | `OTHER_INTERFACE` |
  | usuário pessoal (`MXSD*`, `HQMM*`...) | `OFFLINE_MANUAL` |
  | vazio | `UNKNOWN` |

- **Ligação com o faturamento:** `sales_order_number` da Silver =
  `sales_order_number` da Z17. `customer_reference` traz o chassi nas
  ordens de carro.

## Ordem de aplicação

1. `01_create_stg_va05_sales_order.sql`
2. `02_create_bronze_va05_sales_order.sql`
3. `03_sp_stg_reconcile_va05_sales_order_bronze.sql`
4. `04_create_silver_va05_sales_order_channel.sql`
5. `05_sp_silver_va05_sales_order_channel.sql`

Tudo no schema `bp_datalake`, objetos novos (nada existente é alterado).
Aplicar **antes** do deploy do robô VA05 no `sap-service`.

## Rollback

```sql
DROP PROCEDURE IF EXISTS bp_datalake.sp_silver_va05_sales_order_channel;
DROP PROCEDURE IF EXISTS bp_datalake.sp_stg_reconcile_va05_sales_order_bronze;
DROP TABLE IF EXISTS bp_datalake.silver_va05_sales_order_channel;
DROP TABLE IF EXISTS bp_datalake.bronze_va05_sales_order;
DROP TABLE IF EXISTS bp_datalake.stg_va05_sales_order;
```
