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