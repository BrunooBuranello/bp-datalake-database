-- ============================================================
-- TABELA: bp_datalake.bronze_finance_credit_cars
--
-- OBJETIVO:
-- Foto (snapshot) da aba CARS da planilha CRÉDITO DEALER, usada
-- UMA vez pelo saldo inicial (sp_load_finance_credit_opening_balance,
-- ADR-008 do app finance). Na planilha, a chave chassi + NF estar na
-- CARS faz a BASE marcar a NF como paga inteira (100%); a CARS não
-- tem valor, só a chave e, às vezes, a data do pagamento.
--
-- CARGA:
--   python manage.py load_finance_credit_cars --user <usuário>
--   (app finance). Lê o arquivo da rede com a senha da .env, apaga
--   a foto anterior e grava a nova numa transação. Recusa rodar
--   depois que o saldo inicial foi carregado.
--
-- CAMADA: bronze, fiel à origem: uma linha por linha da aba, com o
-- texto original da chave. As colunas tipadas (chassi, NF, datas)
-- são só a leitura da linha; chave fora do padrão fica com
-- key_valid = 'NO' e não entra no saldo inicial.
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.bronze_finance_credit_cars (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

    load_id CHAR(32) NOT NULL
        COMMENT 'Identifica a foto (uuid hex); todas as linhas de uma carga têm o mesmo',
    source_row_number INT UNSIGNED NOT NULL
        COMMENT 'Linha da aba CARS no Excel',

    key_text VARCHAR(100) NULL
        COMMENT 'Coluna "CHASSI + NF" como veio da planilha',
    key_valid ENUM('YES', 'NO') NOT NULL
        COMMENT 'YES = chassi de 17 + NF numérica',
    chassis_serial_number CHAR(17) NULL,
    invoice_number VARCHAR(9) NULL
        COMMENT 'NF com 9 dígitos (zeros à esquerda), padrão da Z17',
    payment_date DATE NULL
        COMMENT 'Coluna "PAYMENT DATE"',
    entry_date DATE NULL
        COMMENT 'Coluna "DATE"',

    source_file VARCHAR(255) NOT NULL,
    source_file_sha256 CHAR(64) NOT NULL
        COMMENT 'Hash do arquivo criptografado lido',
    source_file_modified_at DATETIME NULL,
    loaded_by VARCHAR(150) NOT NULL,
    loaded_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    INDEX idx_finance_credit_cars_key (chassis_serial_number, invoice_number),
    INDEX idx_finance_credit_cars_load (load_id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Foto da aba CARS da planilha de crédito (saldo inicial, finance ADR-008)';
