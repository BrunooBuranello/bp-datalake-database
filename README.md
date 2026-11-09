# BP Data Lake Database

Projeto responsável pelas estruturas SQL do Data Lake utilizadas no processo de ETL de faturamento.

O objetivo é centralizar as procedures, regras de transformação e modelagem das camadas Bronze, Silver e Gold, garantindo cargas incrementais, rastreabilidade e qualidade dos dados.

---

# Arquitetura

```text
Bronze
   │
   ▼
Silver
   │
   ▼
Gold
```

## Bronze

Camada responsável pela ingestão dos dados provenientes do SAP.

Responsabilidades:

- Receber os dados da origem
- Manter histórico da carga
- Preservar os dados brutos
- Realizar carga incremental

---

## Silver

Camada responsável pelo tratamento dos dados.

Responsabilidades:

- Padronização dos tipos de dados
- Limpeza dos registros
- Aplicação das regras de negócio
- Validação dos dados
- Controle de qualidade
- Carga incremental

---

## Gold

Camada responsável pela disponibilização dos dados para consumo.

Responsabilidades:

- Consolidar um único faturamento por chassi
- Selecionar sempre o faturamento mais recente
- Disponibilizar dados para consultas e indicadores
- Manter rastreabilidade da origem

---

# Procedures

## Histórico DEMO

Arquivos:

```text
database/demo_history/01_create_gold_zsdbil17_demo_history.sql
database/demo_history/02_sp_sync_gold_zsdbil17_demo_history.sql
database/demo_history/03_sp_gold_z17_demo_enrich_dealer.sql
database/demo_history/04_sp_gold_z17_demo_enrich_model.sql
database/demo_history/05_validate_demo_history_pipeline.sql
database/demo_history/06_create_dim_demo_campaign.sql
database/demo_history/07_sp_gold_z17_demo_apply_campaign.sql
database/demo_history/08_alter_dim_demo_campaign_chassis_list.sql
database/demo_history/09_seed_campaign_regularizacao_20261119.sql
```

Ordem dentro da pipeline:

```text
sincronizar eventos e status (prazo padrão 20/30 dias)
    -> enriquecer dealer
    -> enriquecer modelo (bronze_vehicle_material_code)
    -> aplicar campanhas (dim_demo_campaign)
```

Campanhas comerciais (`dim_demo_campaign`) alteram o prazo do ciclo DEMO para
um modelo (prefixo do `model_simplified`, ano-modelo opcional) e uma janela de
**data de emissão** da NF DEMO. A sync continua calculando o padrão; a
`sp_gold_z17_demo_apply_campaign` sobrescreve `warning_date`, `due_date` e
`demo_status` dos ciclos elegíveis e grava as colunas `campaign_*`. `CLOSED`
nunca muda. O fim natural da campanha é o `issuance_to`: DEMOs emitidos dentro
da janela mantêm o prazo até o fim do ciclo. `active = 0` cancela a campanha e
devolve **todos** os ciclos dela ao padrão na execução seguinte.

Campanha por lista (`match_type = 'CHASSIS_LIST'`, script `08`): vale para os
chassis de `dim_demo_campaign_chassis` (só ciclos não `CLOSED`), com
`fixed_due_date` opcional (vencimento fixo) e vigência `valid_from`/`valid_to`
pela **data de hoje**: fora dela a campanha não se aplica e o ciclo volta ao
padrão. `message_before_table` é o texto que o app mostra no aviso por grupo
acima da relação dos chassis. A lista é carregada pelo comando
`load_demo_campaign_chassis` do app (a planilha não vai para o Git). Script
`09`: campanha de regularização dos DEMO vencidos até 19/11/2026.

Ordem de implantação: `06` (tabela e seed), `08` (colunas e tabela de chassis),
`04` e `07` (procedures), `09` (campanha), deploy do app, carga dos chassis,
pipeline (ou `CALL` da `07`) e depois `05` (validação).

Somente uma movimentação posterior com
`access_key_status = 'VALID'` encerra o ciclo DEMO. Status vazio, desconhecido ou
ainda não validado mantém o ciclo aberto para impedir fechamento prematuro.

O enriquecimento de modelo precisa ocorrer depois da sincronização porque o
histórico nasce da Silver, onde `model_simplified` não existe.

## NF-e de saída lidas dos XMLs

Arquivos:

```text
database/nfe_outbound_xml/01_rename_bronze_xml_raw.sql
database/nfe_outbound_xml/02_dedupe_and_unique_access_key.sql
database/nfe_outbound_xml/03_validate_nfe_outbound_xml.sql
database/nfe_outbound_xml/04_drop_bronze_xml_raw_view.sql
```

`bronze_xml_raw` vira `bronze_nfe_outbound_xml` (com VIEW de compatibilidade
no nome antigo), as cópias da mesma chave de acesso são removidas (backup em
`bronze_nfe_outbound_xml_removed_20261109`) e a chave ganha `UNIQUE`. A carga
é feita pelo app (`xml_reader`, comando `load_nfe_outbound_xml`), ao fim do
download diário dos XMLs. Ordem: `01` → `02` → `03` → deploy do app → backfill.
O `04` (09/11/2026) remove a VIEW de compatibilidade `bronze_xml_raw`, que
só o app usava; a partir dele só existe o nome novo.

## Chave de uma NF de veículo (regra do projeto)

Para buscar, comparar ou excluir **uma NF específica de um chassi** na Silver
ou na Gold da Z17, use sempre os quatro campos:

```text
chassis_serial_number + invoice_number + issuance_date + plant_code
```

Nunca só chassi + NF. Cada CNPJ da BYD tem a própria numeração de NF, e o
mesmo chassi pode receber NFs de **mesmo número** de CNPJs diferentes
(transferência por uma filial, venda pela fábrica). Teste na Silver
(`cfop_car = 'YES'`, 06/11/2026):

| Chave | Combinações que apontam para mais de uma NF |
|---|---|
| chassi + NF | 8.081 |
| chassi + NF + data | 67 |
| chassi + NF + data + planta | 3 (histórico antigo: duas filiais, mesma planta, NF, data e série) |

Esses 3 casos só se separam pelo `byd_cnpj_number`. Quem usa a chave de
quatro campos deve tratar o caso "mais de uma NF" como ambíguo (recusar ou
pedir tratamento manual), nunca escolher uma das linhas.

`invoice_number` está sempre com 9 dígitos e zeros à esquerda na Silver: um
valor digitado pelo usuário precisa ser completado antes da comparação.

Legado 2024/2025 (`silver_invoiced_legacy_2024_2025`): desde 06/11/2026 a NF
também tem 9 dígitos (`zsdbil17_legacy/03_update_silver_invoiced_legacy_invoice_padding.sql`
corrigiu a tabela; a `01` já grava assim numa recarga). A Gold recebe o formato
na carga seguinte, pelo append do legado. Ainda diferente da Z17 no legado
(fica para um ADR próprio): `issuance_date` e `plant_code` são `TEXT`, a
collation é `utf8mb4_unicode_ci` e `byd_cnpj_number` vem vazio. Consulta que
junte as duas origens precisa converter tipo e collation, e conversão no
`WHERE` impede o uso do índice: filtre cada tabela pela coluna original e
junte o resultado depois.

## Classificação do tipo de veículo (Silver 07)

Arquivo:

```text
database/procedures/zsdbil17/silver/07_sp_silver_z17_vehicle_type.sql
```

A `sp_silver_z17_vehicle_type` preenche `vehicle_type_code` na Silver, antes
da carga da Gold:

| Prioridade | Regra | Resultado | Entra no Invoiced DB? |
|---|---|---|---|
| 1 | Material em `dim_zsdbil17_material_exclusion` (`active = 1`) | `BUS_TRUCK` | Não |
| 2 | Material em `bronze_vehicle_material_code.cod_sap` | `CAR` | Sim |
| 3 | Sem correspondência | `UNKNOWN` | Sim |

- Desde 09/11/2026 a fonte de carros é a `bronze_vehicle_material_code`
  (cadastro do portal Material Code). A `material_master` legada ficou
  desatualizada: materiais novos caíam em `UNKNOWN`. A tabela nova continha
  todos os códigos da antiga no momento da troca.
- Ônibus e caminhões entram na exclusão manualmente (`INSERT` com `material`,
  `vehicle_category` = `BUS`/`TRUCK` e `description`). Sem isso, eles ficam
  `UNKNOWN`, entram na Gold e aparecem com `model_simplified = 'UNKNOWN'`.
- A procedure só reprocessa linhas `NULL`, vazias ou `UNKNOWN`. Um material
  novo na exclusão ou no Material Code é reclassificado na execução seguinte;
  mudar um material já `CAR`/`BUS_TRUCK` exige reclassificação completa.
- A Gold é recarregada a cada pipeline: a correção na Silver só aparece no
  Invoiced DB depois da próxima execução da pipeline.

## Cancelamento manual de faturamento (paliativo)

Arquivos:

```text
database/procedures/zsdbil17/gold/07_create_dim_zsdbil17_manual_cancellation.sql
database/procedures/zsdbil17/gold/08_sp_z17_apply_manual_cancellation.sql
database/procedures/zsdbil17/gold/09_alter_dim_zsdbil17_manual_cancellation_key.sql
```

Enquanto os cancelamentos não forem estruturados, o time de BP registra no app
**Cancelamentos** do BYD Sales Operation as NFs que a ZSDBIL17 ainda não marca
como `CANCELLED`. O usuário informa chassi + NF + data do faturamento original;
o app confere que existe exatamente uma NF com essa combinação na Silver,
busca a planta e grava em `dim_zsdbil17_manual_cancellation`, com auditoria em
`dim_zsdbil17_manual_cancellation_audit_history`.

A `sp_z17_apply_manual_cancellation` roda depois de `sp_gold_z17_enrich_model`
e antes do DEMO History:

```text
garante colunas na Silver (só na 1ª vez, fora da transação)
    -> Silver: manual_cancellation = 'YES' / manual_cancelled_at (chave ativa)
    -> Gold:   DELETE das NFs canceladas
```

Regras:

- chave = chassi + NF + data + planta (seção acima); NF nova do mesmo chassi
  entra na Gold normalmente;
- sem fallback: a NF anterior do chassi não volta para a Gold;
- `active = 0` (desativar no app) devolve a NF na execução seguinte;
- em erro: ROLLBACK, `ERROR` no `etl_execution_log`, e a pipeline **continua**;
- independente: remover o `CALL` da pipeline desliga o paliativo.
- **Limite conhecido:** o DEMO History lê a Silver e não usa estas colunas.
  Uma venda posterior cancelada manualmente ainda fecha o ciclo DEMO.

Ordem de implantação: `07` (tabelas), `08` (procedure), `CALL` isolado para
criar as colunas da Silver e conferir, e só então a pipeline. O `09` só vale
para a tabela criada pela primeira versão do `07` (chave chassi + NF): rodar
uma vez, com a tabela vazia, e recriar o `08` em seguida.

## Horário da NF na Gold (`proc_time`)

Arquivo:

```text
database/procedures/zsdbil17/gold/10_alter_gold_zsdbil17_add_proc_time.sql
```

A `gold_zsdbil17_faturamento` tem `proc_time` (`TIME`), o horário de
processamento da NF no SAP (coluna "first time" da Z17), copiado da Silver pela
`sp_gold_z17_load_base`. Serve para ordenar faturamentos do mesmo dia
(`issuance_date`, `proc_time`, `invoice_number`) no FIFO da Liberação de
Veículos, que lê apenas a Gold.

- Legado 2024/2025: sempre `NULL` (a origem não tem horário).
- Aplicado em produção em 09/11/2026: `ALTER` + backfill pelo `id_bronze` da
  Silver (206.607 de 206.608 NFs atuais preenchidas) + procedure `02`
  recriada. Instalação nova: o `01` já cria a coluna; não rode o `10`.

## Liberação de Veículos

Pasta `database/vehicle_release/` (tabelas bronze, auditorias `*_audit_history`
e `sp_sync_bronze_vehicle_release`, chamada no passo 18.1 da pipeline Z17).
Regras, escopo e a **chave do CRM (chassi + NF + data)** com a consulta de
referência estão em `database/vehicle_release/README.md`.

## Silver

Arquivo:

```text
database/procedures/create_procedure_silver_faturamento.sql
```

Principais funcionalidades:

- Criação automática da tabela Silver
- Criação automática da tabela de log
- Carga incremental
- Validação de regras de negócio
- Tratamento de erros
- Controle transacional

---

## Gold

Arquivo:

```text
database/procedures/create_procedure_gold_faturamento.sql
```

Principais funcionalidades:

- Criação automática da tabela Gold
- Seleção do faturamento mais recente por chassi
- Carga incremental
- Atualização somente quando houver alteração
- Log de execução
- Tratamento de erros
- Controle transacional

---

# Funcionalidades

- ETL incremental
- Carga idempotente
- Controle transacional
- Tratamento de exceções
- Log de execução
- Rastreabilidade das cargas
- Validação de qualidade dos dados
- Arquitetura Bronze → Silver → Gold

---

# Estrutura do projeto

```text
database/
└── procedures/
    ├── create_procedure_silver_faturamento.sql
    └── create_procedure_gold_faturamento.sql
```

---

# Tecnologias

- MySQL 8
- SQL
- Git
- GitHub

---

# Características técnicas

- Procedures versionadas no Git
- Carga incremental
- Carga idempotente
- Controle de execução
- Tratamento de erros com rollback
- Registro de métricas da execução
- Estrutura preparada para ambiente de produção

---

# Licença

Este projeto foi desenvolvido para fins de estudo e evolução em Engenharia de Dados, utilizando cenários inspirados em ambientes corporativos.
