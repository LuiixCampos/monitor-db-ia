-- Base fictícia de loja, propositalmente SEM índices nas colunas de filtro
CREATE SCHEMA loja;

CREATE TABLE loja.clientes (
  id        serial PRIMARY KEY,
  nome      text,
  email     text,
  cidade    text,
  criado_em timestamptz DEFAULT now()
);

CREATE TABLE loja.pedidos (
  id         bigserial PRIMARY KEY,
  cliente_id int,
  valor      numeric(10,2),
  status     text,
  criado_em  timestamptz
);

INSERT INTO loja.clientes (nome, email, cidade)
SELECT 'Cliente ' || g,
       'cliente' || g || '@exemplo.com',
       (ARRAY['Sao Paulo','Porto Alegre','Curitiba','Recife','Belo Horizonte','Salvador'])[1 + g % 6]
FROM generate_series(1, 50000) g;

INSERT INTO loja.pedidos (cliente_id, valor, status, criado_em)
SELECT 1 + (random() * 49999)::int,
       round((random() * 1000)::numeric, 2),
       (ARRAY['PAGO','PENDENTE','CANCELADO','ENTREGUE'])[1 + (random() * 3)::int],
       now() - (random() * interval '365 days')
FROM generate_series(1, 1000000);

ANALYZE loja.clientes;
ANALYZE loja.pedidos;
