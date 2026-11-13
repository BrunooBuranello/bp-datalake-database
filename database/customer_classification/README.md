# Classificação de clientes por CNPJ — SQL

Tabela de regra mantida à mão, direto no banco (sem tela no app por
enquanto). Serve para qualquer app classificar um cliente pelo CNPJ.

## Arquivos (ordem de implantação)

| Arquivo | Objeto | Função |
|---|---|---|
| `01_create_dim_customer_classification.sql` | `dim_customer_classification` | Um CNPJ + um tipo por linha; raiz do CNPJ calculada pelo banco |

## Tipos

| `classification_type` | Significado | Quem usa |
|---|---|---|
| `RENTAL_COMPANY` | Locadora | Ninguém ainda: as regras de locadora da Liberação de Veículos ficam para depois (12/11/2026) |

Tipo novo: documentar aqui e no cabeçalho do DDL **antes** de cadastrar.

## Regras de manutenção

- Nunca `DELETE`: para tirar um CNPJ, `is_active = 'NO'` e motivo em `notes`.
- CNPJ só com dígitos (14). O banco recusa outro formato.
- Sempre preencher `created_by` / `updated_by`.

## Consultas úteis

```sql
-- Locadoras ativas
SELECT customer_cnpj, customer_name
FROM bp_datalake.dim_customer_classification
WHERE classification_type = 'RENTAL_COMPANY'
  AND is_active = 'YES'
ORDER BY customer_name;
```

## Uso

- `sp_sync_bronze_vehicle_release` (Liberação de Veículos): Venda Direta (B5)
  com sold-to CNPJ ativo como `RENTAL_COMPANY` entra no Grupo 1 (mesmas regras
  da Revenda). Casamento pelo **CNPJ completo**.
- Carga inicial em 12/11/2026: 8 CNPJs de 5 locadoras, do e-mail do
  Financeiro (dígitos verificadores conferidos antes do INSERT).
