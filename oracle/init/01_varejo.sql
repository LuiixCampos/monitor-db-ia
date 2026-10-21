-- =====================================================================
-- Oracle Free (lab): versão enxuta da base fictícia de varejo, no schema
-- VAREJO (criado pela imagem via APP_USER). Sem índices nas colunas de
-- filtro, de propósito, para gerar SQL lento no V$SQL.
-- Executado automaticamente na primeira subida do container (como SYS).
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = VAREJO;

CREATE TABLE lojas (
  id      NUMBER PRIMARY KEY,
  codigo  VARCHAR2(10),
  nome    VARCHAR2(60),
  cidade  VARCHAR2(40),
  uf      CHAR(2),
  regiao  VARCHAR2(20),
  tipo    VARCHAR2(10)
);

CREATE TABLE produtos (
  id           NUMBER PRIMARY KEY,
  sku          VARCHAR2(12),
  descricao    VARCHAR2(80),
  departamento VARCHAR2(20),
  preco        NUMBER(10,2),
  custo        NUMBER(10,2)
);

CREATE TABLE vendas (
  id          NUMBER PRIMARY KEY,
  loja_id     NUMBER,
  cliente_id  NUMBER,
  data_hora   DATE,
  canal       VARCHAR2(12),
  status      VARCHAR2(12),
  valor_total NUMBER(12,2)
);

CREATE TABLE itens_venda (
  id             NUMBER PRIMARY KEY,
  venda_id       NUMBER,
  produto_id     NUMBER,
  quantidade     NUMBER,
  preco_unitario NUMBER(10,2)
);

CREATE TABLE estoque (
  id             NUMBER PRIMARY KEY,
  loja_id        NUMBER,
  produto_id     NUMBER,
  qtd_disponivel NUMBER
);

INSERT /*+ APPEND */ INTO lojas
SELECT LEVEL,
       'L' || LPAD(LEVEL, 4, '0'),
       'Loja ' || LEVEL,
       DECODE(MOD(LEVEL, 6), 0, 'Sao Paulo', 1, 'Porto Alegre', 2, 'Recife', 3, 'Curitiba', 4, 'Manaus', 'Salvador'),
       DECODE(MOD(LEVEL, 6), 0, 'SP', 1, 'RS', 2, 'PE', 3, 'PR', 4, 'AM', 'BA'),
       DECODE(MOD(LEVEL, 6), 0, 'Sudeste', 1, 'Sul', 2, 'Nordeste', 3, 'Sul', 4, 'Norte', 'Nordeste'),
       CASE WHEN MOD(LEVEL, 3) = 0 THEN 'RUA' ELSE 'SHOPPING' END
FROM dual CONNECT BY LEVEL <= 100;
COMMIT;

INSERT /*+ APPEND */ INTO produtos
SELECT LEVEL,
       'SKU' || LPAD(LEVEL, 6, '0'),
       'Produto ' || LEVEL,
       DECODE(MOD(LEVEL, 6), 0, 'FEMININO', 1, 'MASCULINO', 2, 'INFANTIL', 3, 'CALCADOS', 4, 'ACESSORIOS', 'CASA'),
       ROUND(29.9 + DBMS_RANDOM.VALUE(0, 470), 2),
       0
FROM dual CONNECT BY LEVEL <= 10000;
UPDATE produtos SET custo = ROUND(preco * 0.45, 2);
COMMIT;

-- 300 mil vendas (CONNECT BY em duas camadas para não estourar memória)
INSERT /*+ APPEND */ INTO vendas
SELECT ROWNUM,
       TRUNC(DBMS_RANDOM.VALUE(1, 101)),
       TRUNC(DBMS_RANDOM.VALUE(1, 100001)),
       SYSDATE - DBMS_RANDOM.VALUE(0, 365),
       DECODE(TRUNC(DBMS_RANDOM.VALUE(0, 5)), 3, 'ECOMMERCE', 4, 'APP', 'LOJA'),
       CASE WHEN DBMS_RANDOM.VALUE < 0.03 THEN 'CANCELADA' ELSE 'CONCLUIDA' END,
       ROUND(DBMS_RANDOM.VALUE(30, 900), 2)
FROM (SELECT 1 FROM dual CONNECT BY LEVEL <= 1000),
     (SELECT 1 FROM dual CONNECT BY LEVEL <= 300);
COMMIT;

-- 600 mil itens (2 por venda)
INSERT /*+ APPEND */ INTO itens_venda
SELECT ROWNUM, v.id, TRUNC(DBMS_RANDOM.VALUE(1, 10001)), TRUNC(DBMS_RANDOM.VALUE(1, 4)), ROUND(DBMS_RANDOM.VALUE(30, 500), 2)
FROM vendas v, (SELECT 1 FROM dual CONNECT BY LEVEL <= 2);
COMMIT;

-- 250 mil linhas de estoque (cada loja com 2.500 SKUs)
INSERT /*+ APPEND */ INTO estoque
SELECT ROWNUM, l.id, p.id,
       CASE WHEN DBMS_RANDOM.VALUE < 0.07 THEN 0 ELSE TRUNC(DBMS_RANDOM.VALUE(1, 50)) END
FROM lojas l, produtos p
WHERE MOD(p.id + l.id, 4) = 0;
COMMIT;

BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS('VAREJO');
END;
/
