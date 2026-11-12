-- ============================================================
-- TABELA: bp_datalake.dim_customer_classification
-- CAMADA: dim (tabela de regra, mantida à mão)
--
-- OBJETIVO:
-- Classificar clientes pelo CNPJ, para qualquer app usar (não é
-- só da Liberação de Veículos). Um CNPJ pode ter mais de uma
-- classificação; cada uma é uma linha. Novos tipos entram sem DDL
-- novo, só documentando aqui e no README antes de usar.
--
-- TIPOS (classification_type):
--   RENTAL_COMPANY  Locadora. Cadastro em 12/11/2026; as regras da
--                   Liberação que usam este tipo ainda NÃO existem
--                   (decisão do Bruno: aplicar depois).
--
-- CNPJ COMPLETO x RAIZ:
-- Guarda o CNPJ completo (14 dígitos). A raiz (8 dígitos) sai na
-- coluna gerada customer_cnpj_root, para a regra futura escolher
-- comparar por filial ou pela empresa inteira (ainda em validação).
--
-- COMO MANTER:
-- - Nunca DELETE: para tirar alguém, is_active = 'NO' (o histórico
--   de quem estava classificado fica preservado).
-- - Sempre preencher created_by / updated_by com o seu usuário.
-- - customer_cnpj só com dígitos (sem ponto, barra ou traço).
--
-- Exemplo (dados fictícios):
--   INSERT INTO bp_datalake.dim_customer_classification
--       (customer_cnpj, classification_type, customer_name, created_by)
--   VALUES ('11222333000181', 'RENTAL_COMPANY', 'LOCADORA EXEMPLO', 'bruno');
--
--   UPDATE bp_datalake.dim_customer_classification
--   SET is_active = 'NO', updated_by = 'bruno', notes = 'motivo'
--   WHERE classification_type = 'RENTAL_COMPANY'
--     AND customer_cnpj = '11222333000181';
--
-- LIDA POR: ninguém ainda (regras de locadora ficam para depois).
-- ============================================================

CREATE TABLE IF NOT EXISTS bp_datalake.dim_customer_classification (

    id BIGINT NOT NULL AUTO_INCREMENT,

    customer_cnpj CHAR(14) NOT NULL
        COMMENT 'CNPJ completo do cliente, 14 dígitos sem pontuação',
    customer_cnpj_root CHAR(8)
        GENERATED ALWAYS AS (LEFT(customer_cnpj, 8)) STORED
        COMMENT 'Raiz do CNPJ (8 dígitos), calculada pelo banco',
    classification_type VARCHAR(50) NOT NULL
        COMMENT 'RENTAL_COMPANY (novos tipos documentados no DDL/README)',
    customer_name VARCHAR(255) NULL
        COMMENT 'Nome para leitura humana (ex.: razão social)',
    is_active CHAR(3) NOT NULL DEFAULT 'YES'
        COMMENT 'YES = vale; NO = desativado (nunca apagar)',
    notes VARCHAR(500) NULL
        COMMENT 'Motivo da inclusão/desativação, quem pediu',

    created_by VARCHAR(150) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by VARCHAR(150) NULL,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),

    -- Um CNPJ não se repete dentro do mesmo tipo.
    UNIQUE KEY uk_customer_classification (classification_type, customer_cnpj),

    -- Para a regra futura que comparar pela raiz.
    KEY idx_customer_classification_root (classification_type, customer_cnpj_root),

    CONSTRAINT chk_customer_classification_cnpj
        CHECK (REGEXP_LIKE(customer_cnpj, '^[0-9]{14}$')),
    CONSTRAINT chk_customer_classification_active
        CHECK (is_active IN ('YES', 'NO'))

)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_0900_ai_ci
COMMENT = 'Classificação de clientes por CNPJ mantida à mão (ex.: locadoras)';
