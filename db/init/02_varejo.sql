-- =====================================================================
-- Base FICTÍCIA de varejo de moda (modelo genérico, nenhum dado real)
-- Índices só nas PKs, de propósito: as FKs e filtros ficam sem índice
-- para gerar queries lentas que o monitor vai detectar.
-- Volume aproximado: 200 lojas, 20 mil SKUs, 200 mil clientes,
-- 1 milhão de vendas, 2 milhões de itens, 1 milhão de linhas de estoque,
-- 300 mil transferências e 480 mil itens de inventário.
-- =====================================================================
DO $$ BEGIN PERFORM setseed(0.42); END $$;

CREATE SCHEMA varejo;

CREATE TABLE varejo.lojas (
  id            serial PRIMARY KEY,
  codigo        text,
  nome          text,
  cidade        text,
  uf            char(2),
  regiao        text,
  tipo          text,          -- CD, SHOPPING, RUA
  data_abertura date
);

CREATE TABLE varejo.produtos (
  id           serial PRIMARY KEY,
  sku          text,
  descricao    text,
  departamento text,
  categoria    text,
  cor          text,
  tamanho      text,
  colecao      text,
  preco        numeric(10,2),
  custo        numeric(10,2),
  ativo        boolean
);

CREATE TABLE varejo.clientes (
  id            serial PRIMARY KEY,
  nome          text,
  email         text,
  cidade        text,
  uf            char(2),
  data_cadastro date
);

CREATE TABLE varejo.vendas (
  id              bigserial PRIMARY KEY,
  loja_id         int,
  cliente_id      int,           -- NULL = venda sem identificação
  data_hora       timestamptz,
  canal           text,          -- LOJA, ECOMMERCE, APP
  forma_pagamento text,
  status          text,
  valor_total     numeric(12,2)
);

CREATE TABLE varejo.itens_venda (
  id             bigserial PRIMARY KEY,
  venda_id       bigint,
  produto_id     int,
  quantidade     int,
  preco_unitario numeric(10,2),
  desconto       numeric(10,2)
);

CREATE TABLE varejo.estoque (
  id             bigserial PRIMARY KEY,
  loja_id        int,
  produto_id     int,
  qtd_disponivel int,
  qtd_reservada  int,
  atualizado_em  timestamptz
);

CREATE TABLE varejo.transferencias (
  id              bigserial PRIMARY KEY,
  loja_origem     int,
  loja_destino    int,
  produto_id      int,
  quantidade      int,
  status          text,          -- SOLICITADA, EM_TRANSITO, RECEBIDA, CANCELADA
  dt_solicitacao  timestamptz,
  dt_recebimento  timestamptz
);

CREATE TABLE varejo.inventarios (
  id              serial PRIMARY KEY,
  loja_id         int,
  data_inventario date,
  status          text
);

CREATE TABLE varejo.inventario_itens (
  id            bigserial PRIMARY KEY,
  inventario_id int,
  produto_id    int,
  qtd_sistema   int,
  qtd_contada   int
);

-- Cidades de referência
CREATE TEMP TABLE cid (n int, cidade text, uf char(2), regiao text);
INSERT INTO cid VALUES
 (0,'Sao Paulo','SP','Sudeste'),(1,'Rio de Janeiro','RJ','Sudeste'),(2,'Belo Horizonte','MG','Sudeste'),
 (3,'Porto Alegre','RS','Sul'),(4,'Curitiba','PR','Sul'),(5,'Florianopolis','SC','Sul'),
 (6,'Salvador','BA','Nordeste'),(7,'Recife','PE','Nordeste'),(8,'Fortaleza','CE','Nordeste'),
 (9,'Brasilia','DF','Centro-Oeste'),(10,'Goiania','GO','Centro-Oeste'),(11,'Manaus','AM','Norte');

-- Lojas (1 a 3 são centros de distribuição)
INSERT INTO varejo.lojas (codigo, nome, cidade, uf, regiao, tipo, data_abertura)
SELECT 'L' || lpad(g::text, 4, '0'),
       CASE WHEN g <= 3 THEN 'CD ' ELSE 'Loja ' END || c.cidade || ' ' || g,
       c.cidade, c.uf, c.regiao,
       CASE WHEN g <= 3 THEN 'CD' WHEN g % 3 = 0 THEN 'RUA' ELSE 'SHOPPING' END,
       date '2000-01-01' + (random() * 9000)::int
FROM generate_series(1, 200) g
JOIN cid c ON c.n = g % 12;

-- Produtos
CREATE TEMP TABLE cat (n int, categoria text, departamento text);
INSERT INTO cat VALUES
 (0,'Blusa','FEMININO'),(1,'Vestido','FEMININO'),(2,'Saia','FEMININO'),
 (3,'Camisa','MASCULINO'),(4,'Bermuda','MASCULINO'),(5,'Calca','MASCULINO'),
 (6,'Conjunto','INFANTIL'),(7,'Pijama','INFANTIL'),(8,'Tenis','CALCADOS'),
 (9,'Sandalia','CALCADOS'),(10,'Bolsa','ACESSORIOS'),(11,'Toalha','CASA');

INSERT INTO varejo.produtos (sku, descricao, departamento, categoria, cor, tamanho, colecao, preco, custo, ativo)
SELECT 'SKU' || lpad(g::text, 6, '0'),
       c.categoria || ' ' || cor || ' ' || tam,
       c.departamento, c.categoria, cor, tam,
       (ARRAY['VER25','INV25','VER26','INV26'])[1 + g % 4],
       preco, round(preco * 0.45, 2),
       random() > 0.1
FROM (
  SELECT g,
         (ARRAY['Preto','Branco','Azul','Vermelho','Verde','Bege','Rosa','Cinza'])[1 + floor(random() * 8)::int] AS cor,
         (ARRAY['PP','P','M','G','GG','UN'])[1 + floor(random() * 6)::int] AS tam,
         round((29.90 + random() * 470)::numeric, 2) AS preco
  FROM generate_series(1, 20000) g
) x
JOIN cat c ON c.n = x.g % 12;

-- Clientes
INSERT INTO varejo.clientes (nome, email, cidade, uf, data_cadastro)
SELECT (ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Hugo','Isabela','Joao','Larissa','Marcos'])[1 + floor(random() * 12)::int]
       || ' ' ||
       (ARRAY['Silva','Souza','Oliveira','Santos','Lima','Pereira','Costa','Almeida','Rocha','Martins'])[1 + floor(random() * 10)::int],
       'cliente' || g || '@exemplo.com',
       c.cidade, c.uf,
       date '2015-01-01' + (random() * 4000)::int
FROM generate_series(1, 200000) g
JOIN cid c ON c.n = g % 12;

-- Vendas (último ano)
INSERT INTO varejo.vendas (loja_id, cliente_id, data_hora, canal, forma_pagamento, status, valor_total)
SELECT 4 + floor(random() * 197)::int,
       CASE WHEN random() < 0.4 THEN NULL ELSE 1 + floor(random() * 200000)::int END,
       now() - random() * interval '365 days',
       (ARRAY['LOJA','LOJA','LOJA','ECOMMERCE','APP'])[1 + floor(random() * 5)::int],
       (ARRAY['CREDITO','DEBITO','PIX','CARTAO_LOJA','DINHEIRO'])[1 + floor(random() * 5)::int],
       CASE WHEN random() < 0.03 THEN 'CANCELADA' ELSE 'CONCLUIDA' END,
       0
FROM generate_series(1, 1000000);

-- Itens de venda (1 a 3 por venda)
INSERT INTO varejo.itens_venda (venda_id, produto_id, quantidade, preco_unitario, desconto)
SELECT x.venda_id, x.produto_id, x.qtd, p.preco,
       CASE WHEN random() < 0.2 THEN round(p.preco * x.qtd * 0.10, 2) ELSE 0 END
FROM (
  SELECT v.id AS venda_id,
         1 + floor(random() * 20000)::int AS produto_id,
         1 + floor(random() * 3)::int     AS qtd
  FROM varejo.vendas v, generate_series(1, 1 + (v.id % 3)::int)
) x
JOIN varejo.produtos p ON p.id = x.produto_id;

UPDATE varejo.vendas v
SET valor_total = t.total
FROM (SELECT venda_id, sum(quantidade * preco_unitario - desconto) AS total
      FROM varejo.itens_venda GROUP BY venda_id) t
WHERE t.venda_id = v.id;

-- Estoque (cada loja trabalha com ~5 mil SKUs; ~5% em ruptura)
INSERT INTO varejo.estoque (loja_id, produto_id, qtd_disponivel, qtd_reservada, atualizado_em)
SELECT l.id, p.id,
       CASE WHEN random() < 0.05 THEN 0 ELSE floor(random() * 50)::int END,
       floor(random() * 3)::int,
       now() - random() * interval '10 days'
FROM varejo.lojas l
JOIN varejo.produtos p ON (p.id + l.id) % 4 = 0;

-- Transferências (maioria saindo dos CDs)
INSERT INTO varejo.transferencias (loja_origem, loja_destino, produto_id, quantidade, status, dt_solicitacao, dt_recebimento)
SELECT origem, destino, produto, qtd, st, dt,
       CASE WHEN st = 'RECEBIDA' THEN dt + random() * interval '10 days' END
FROM (
  SELECT CASE WHEN random() < 0.8 THEN 1 + floor(random() * 3)::int ELSE 4 + floor(random() * 197)::int END AS origem,
         4 + floor(random() * 197)::int AS destino,
         1 + floor(random() * 20000)::int AS produto,
         1 + floor(random() * 20)::int AS qtd,
         (ARRAY['RECEBIDA','RECEBIDA','RECEBIDA','RECEBIDA','EM_TRANSITO','SOLICITADA','CANCELADA'])[1 + floor(random() * 7)::int] AS st,
         now() - random() * interval '180 days' AS dt
  FROM generate_series(1, 300000)
) t;

-- Inventários (3 por loja) e itens com ~8% de divergência
INSERT INTO varejo.inventarios (loja_id, data_inventario, status)
SELECT l.id, current_date - (n * 90 + floor(random() * 30)::int), 'FINALIZADO'
FROM varejo.lojas l, generate_series(0, 2) n
WHERE l.tipo <> 'CD';

INSERT INTO varejo.inventario_itens (inventario_id, produto_id, qtd_sistema, qtd_contada)
SELECT inventario_id, produto_id, qs,
       CASE WHEN random() < 0.08 THEN greatest(qs - 1 - floor(random() * 3)::int, 0) ELSE qs END
FROM (
  SELECT i.id AS inventario_id, p.id AS produto_id, floor(random() * 50)::int AS qs
  FROM varejo.inventarios i
  JOIN varejo.produtos p ON (p.id + i.id) % 25 = 0
) x;

ANALYZE;
