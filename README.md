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

Ordem de implantação: `06` (tabela e seed), `04` e `07` (procedures), pipeline e
depois `05` (validação).

Somente uma movimentação posterior com
`access_key_status = 'VALID'` encerra o ciclo DEMO. Status vazio, desconhecido ou
ainda não validado mantém o ciclo aberto para impedir fechamento prematuro.

O enriquecimento de modelo precisa ocorrer depois da sincronização porque o
histórico nasce da Silver, onde `model_simplified` não existe.

## Cancelamento manual de faturamento (paliativo)

Arquivos:

```text
database/procedures/zsdbil17/gold/07_create_dim_zsdbil17_manual_cancellation.sql
database/procedures/zsdbil17/gold/08_sp_z17_apply_manual_cancellation.sql
```

Enquanto os cancelamentos não forem estruturados, o time de BP registra no app
**Cancelamentos** do BYD Sales Operation as NFs que a ZSDBIL17 ainda não marca
como `CANCELLED`. O usuário informa chassi + data do faturamento original; o
app busca a NF na Silver e grava em `dim_zsdbil17_manual_cancellation`, com
auditoria em `dim_zsdbil17_manual_cancellation_audit_history`.

A `sp_z17_apply_manual_cancellation` roda depois de `sp_gold_z17_enrich_model`
e antes do DEMO History:

```text
garante colunas na Silver (só na 1ª vez, fora da transação)
    -> Silver: manual_cancellation = 'YES' / manual_cancelled_at (chassi + NF ativos)
    -> Gold:   DELETE das NFs canceladas
```

Regras:

- chave = chassi + NF; NF nova do mesmo chassi entra na Gold normalmente;
- sem fallback: a NF anterior do chassi não volta para a Gold;
- `active = 0` (desativar no app) devolve a NF na execução seguinte;
- em erro: ROLLBACK, `ERROR` no `etl_execution_log`, e a pipeline **continua**;
- independente: remover o `CALL` da pipeline desliga o paliativo.
- **Limite conhecido:** o DEMO History lê a Silver e não usa estas colunas.
  Uma venda posterior cancelada manualmente ainda fecha o ciclo DEMO.

Ordem de implantação: `07` (tabelas), `08` (procedure), `CALL` isolado para
criar as colunas da Silver e conferir, e só então a pipeline.

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
