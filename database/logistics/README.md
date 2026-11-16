# Veículos › Logística — SQL

Tabelas do app `logistics` do BYD Sales Operation (ADR-001 e ADR-002 de
`logistics/docs/DECISIONS.md`). Substituem a planilha "PERFORMANCE GERAL" do
time de Logística (embarques de veículos por transportadora).

| Na planilha | Vira |
|---|---|
| Abas por planta e período (histórico até a data de corte) | `bronze_logistics_shipment_legacy` (carga única, tudo `TEXT`) |
| Digitação diária nas abas | `bronze_logistics_shipment` (tela do app, conferida na Gold Z17) |
| Quem digitou | `bronze_logistics_shipment_audit_history` |

## Arquivos (ordem de implantação)

| Arquivo | Objeto | Função |
|---|---|---|
| `01_create_bronze_logistics_shipment_legacy.sql` | `bronze_logistics_shipment_legacy` | Histórico da planilha, fiel à origem (39 colunas em `TEXT` + controle da carga) |
| `02_create_bronze_logistics_shipment.sql` | `bronze_logistics_shipment` | Lançamentos da tela (append-only; situação atual = lançamento mais recente da NF) |
| `03_create_bronze_logistics_shipment_audit_history.sql` | `..._audit_history` | Quem lançou, quando, em qual lote |

**Ordem do deploy:** 01 → 02 → 03 → app → carga do histórico:

```text
python manage.py load_logistics_legacy --file "<caminho>\PERFORMANCE GERAL NOVO.xlsx" --user <usuário>
```

A carga roda dentro do semáforo de gravação pesada (ADR-010 de `docs/DECISIONS.md` do app Django) e recusa
um arquivo já carregado (mesmo `source_file`). Use `--dry-run` para só contar
as linhas por aba sem gravar.

## Regras

- **Chave da NF:** chassi + NF (9 dígitos) + data de emissão + planta, como no
  resto do projeto. O app confere na `gold_zsdbil17_faturamento`; chave que
  aponta para mais de uma NF é recusada.
- **Histórico (`_legacy`):** carrega as abas por planta e período; a aba
  "PERFORMANCE GERAL" é a soma delas e fica fora (evita linha em dobro). Abas
  de rascunho (`Planilha1`, `Planilha2`, `CONSULTA`) também ficam fora.
- **Coluna `cnpj` do histórico:** traz a planta emissora ("BYD - ES"…), não um
  CNPJ. O nome segue a planilha (não corrigimos em silêncio).
- **Próximo passo:** Silver única (`silver_logistics_shipment`) juntando o
  histórico limpo e os lançamentos da tela, com datas tipadas e de-para de
  modalidade, pátio e transportadora.

## Conferência

```sql
-- Linhas por aba carregada
SELECT source_sheet, COUNT(*) AS linhas
FROM bp_datalake.bronze_logistics_shipment_legacy
GROUP BY source_sheet
ORDER BY source_sheet;

-- Último lançamento de cada NF (situação atual)
SELECT s.*
FROM bp_datalake.bronze_logistics_shipment AS s
JOIN (
    SELECT chassis_serial_number, invoice_number, issuance_date, plant_code, MAX(id) AS last_id
    FROM bp_datalake.bronze_logistics_shipment
    GROUP BY chassis_serial_number, invoice_number, issuance_date, plant_code
) AS last ON last.last_id = s.id;
```
