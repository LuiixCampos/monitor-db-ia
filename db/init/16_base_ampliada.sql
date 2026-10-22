-- =====================================================================
-- Base ampliada: os sistemas de uma varejista de moda de grande porte
-- (modelo genérico e FICTÍCIO, nenhum dado ou estrutura real de cliente).
--
--   varejo      ERP de loja e CD: + fornecedores, pedidos de compra,
--               kardex (movimentações de estoque), trocas e devoluções
--               e mais um ano de histórico de vendas
--   fiscal      notas fiscais (NFC-e de venda, NF-e de transferência e
--               de compra), itens e eventos de autorização na SEFAZ
--   integracao  fila de eventos loja -> central (réplica/integração),
--               com lojas acumulando atraso
--
-- E-commerce fica no MySQL, cartão próprio no SQL Server e catálogo do
-- app no MongoDB (ver db/mysql, db/sqlserver e db/mongodb).
--
-- Volume com ESCALA_BASE=1: ~19 milhões de linhas a mais (total ~24 mi, ~3 GB).
-- Leva uns 2 minutos numa máquina com 2 CPUs.
-- A escala vem de PGOPTIONS="-c lab.escala=N" (definido no docker-compose).
-- Rodar uma vez só. Num banco já existente:
--   docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/16_base_ampliada.sql
-- =====================================================================
\set ON_ERROR_STOP on
-- Tudo numa transação: se der erro no meio, nada fica pela metade
BEGIN;

DO $$ BEGIN
  IF to_regclass('fiscal.notas') IS NOT NULL THEN
    RAISE EXCEPTION 'Base ampliada já foi criada neste banco (fiscal.notas existe).';
  END IF;
  PERFORM setseed(0.1234);
END $$;

CREATE FUNCTION pg_temp.n(base bigint) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT greatest(1, round(base * coalesce(nullif(current_setting('lab.escala', true), ''), '1')::numeric))::bigint
$$;

SELECT 'Escala da base: ' || coalesce(nullif(current_setting('lab.escala', true), ''), '1') AS info;

-- ---------------------------------------------------------------------
-- VAREJO: mais um ano de histórico de vendas (o mais antigo)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE corte AS SELECT max(id) AS ultima_venda FROM varejo.vendas;

INSERT INTO varejo.vendas (loja_id, cliente_id, data_hora, canal, forma_pagamento, status, valor_total)
SELECT 4 + floor(random() * 197)::int,
       CASE WHEN random() < 0.4 THEN NULL ELSE 1 + floor(random() * 200000)::int END,
       now() - interval '365 days' - random() * interval '365 days',
       (ARRAY['LOJA','LOJA','LOJA','ECOMMERCE','APP'])[1 + floor(random() * 5)::int],
       (ARRAY['CREDITO','DEBITO','PIX','CARTAO_LOJA','DINHEIRO'])[1 + floor(random() * 5)::int],
       CASE WHEN random() < 0.03 THEN 'CANCELADA' ELSE 'CONCLUIDA' END,
       0
FROM generate_series(1, pg_temp.n(1000000));

INSERT INTO varejo.itens_venda (venda_id, produto_id, quantidade, preco_unitario, desconto)
SELECT x.venda_id, x.produto_id, x.qtd, p.preco,
       CASE WHEN random() < 0.2 THEN round(p.preco * x.qtd * 0.10, 2) ELSE 0 END
FROM (
  SELECT v.id AS venda_id, 1 + floor(random() * 20000)::int AS produto_id, 1 + floor(random() * 3)::int AS qtd
  FROM varejo.vendas v, generate_series(1, 1 + (v.id % 3)::int)
  WHERE v.id > (SELECT ultima_venda FROM corte)
) x
JOIN varejo.produtos p ON p.id = x.produto_id;

UPDATE varejo.vendas v
SET valor_total = t.total
FROM (SELECT venda_id, sum(quantidade * preco_unitario - desconto) AS total
      FROM varejo.itens_venda WHERE venda_id > (SELECT ultima_venda FROM corte) GROUP BY venda_id) t
WHERE t.venda_id = v.id;

-- ---------------------------------------------------------------------
-- VAREJO: fornecedores e pedidos de compra (abastecem os CDs 1 a 3)
-- ---------------------------------------------------------------------
CREATE TABLE varejo.fornecedores (
  id                 serial PRIMARY KEY,
  cnpj               text,
  razao_social       text,
  uf                 char(2),
  departamento       text,
  prazo_entrega_dias int
);

INSERT INTO varejo.fornecedores (cnpj, razao_social, uf, departamento, prazo_entrega_dias)
SELECT lpad((10000000 + g * 7919)::text, 8, '0') || '0001' || lpad((g % 97)::text, 2, '0'),
       (ARRAY['Confeccoes','Textil','Calcados','Malhas','Industria','Moda'])[1 + g % 6] || ' Fornecedor ' || g || ' Ltda',
       (ARRAY['SP','SC','RS','CE','MG','PR','GO','PE'])[1 + g % 8],
       (ARRAY['FEMININO','MASCULINO','INFANTIL','CALCADOS','ACESSORIOS','CASA'])[1 + g % 6],
       10 + (g % 50)
FROM generate_series(1, 2000) g;

CREATE TABLE varejo.pedidos_compra (
  id             bigserial PRIMARY KEY,
  fornecedor_id  int,
  cd_id          int,
  dt_pedido      timestamptz,
  dt_prevista    date,
  dt_recebimento timestamptz,
  status         text,          -- ABERTO, PARCIAL, RECEBIDO, CANCELADO
  valor_total    numeric(14,2)
);

INSERT INTO varejo.pedidos_compra (fornecedor_id, cd_id, dt_pedido, dt_prevista, dt_recebimento, status, valor_total)
SELECT f, 1 + floor(random() * 3)::int, dt, (dt + make_interval(days => 10 + f % 50))::date,
       CASE WHEN st IN ('RECEBIDO', 'PARCIAL') THEN dt + make_interval(days => 8 + f % 50 + floor(random() * 15)::int) END,
       st, 0
FROM (
  SELECT 1 + floor(random() * 2000)::int AS f,
         now() - random() * interval '540 days' AS dt,
         (ARRAY['RECEBIDO','RECEBIDO','RECEBIDO','RECEBIDO','RECEBIDO','PARCIAL','ABERTO','CANCELADO'])[1 + floor(random() * 8)::int] AS st
  FROM generate_series(1, pg_temp.n(40000))
) x;
-- Pedido futuro não pode estar recebido
UPDATE varejo.pedidos_compra SET status = 'ABERTO', dt_recebimento = NULL WHERE dt_recebimento > now();

CREATE TABLE varejo.pedidos_compra_itens (
  id             bigserial PRIMARY KEY,
  pedido_id      bigint,
  produto_id     int,
  qtd_pedida     int,
  qtd_recebida   int,
  custo_unitario numeric(10,2)
);

INSERT INTO varejo.pedidos_compra_itens (pedido_id, produto_id, qtd_pedida, qtd_recebida, custo_unitario)
SELECT pc.id, p.id, q,
       CASE pc.status WHEN 'RECEBIDO' THEN q WHEN 'PARCIAL' THEN floor(q * random())::int ELSE 0 END,
       p.custo
FROM varejo.pedidos_compra pc
CROSS JOIN LATERAL (SELECT 1 + floor(random() * 20000)::int AS pid, (20 + floor(random() * 30)::int) * 10 AS q
                    FROM generate_series(1, 10 + (pc.id % 21)::int)) g
JOIN varejo.produtos p ON p.id = g.pid;

UPDATE varejo.pedidos_compra pc SET valor_total = t.v
FROM (SELECT pedido_id, sum(qtd_pedida * custo_unitario) v FROM varejo.pedidos_compra_itens GROUP BY pedido_id) t
WHERE t.pedido_id = pc.id;

-- ---------------------------------------------------------------------
-- VAREJO: trocas e devoluções (~4% das vendas de loja)
-- ---------------------------------------------------------------------
CREATE TABLE varejo.trocas_devolucoes (
  id          bigserial PRIMARY KEY,
  venda_id    bigint,
  loja_id     int,
  produto_id  int,
  quantidade  int,
  tipo        text,      -- TROCA, DEVOLUCAO
  motivo      text,
  dt_registro timestamptz
);

INSERT INTO varejo.trocas_devolucoes (venda_id, loja_id, produto_id, quantidade, tipo, motivo, dt_registro)
SELECT i.venda_id, v.loja_id, i.produto_id, 1,
       CASE WHEN random() < 0.75 THEN 'TROCA' ELSE 'DEVOLUCAO' END,
       (ARRAY['TAMANHO','TAMANHO','TAMANHO','COR','DEFEITO','ARREPENDIMENTO','PRESENTE'])[1 + floor(random() * 7)::int],
       v.data_hora + random() * interval '30 days'
FROM varejo.itens_venda i
JOIN varejo.vendas v ON v.id = i.venda_id
WHERE v.status = 'CONCLUIDA' AND random() < 0.04;
DELETE FROM varejo.trocas_devolucoes WHERE dt_registro > now();

-- ---------------------------------------------------------------------
-- VAREJO: kardex (toda entrada e saída de estoque, por loja e SKU)
-- ---------------------------------------------------------------------
CREATE TABLE varejo.movimentacoes_estoque (
  id           bigserial PRIMARY KEY,
  loja_id      int,
  produto_id   int,
  tipo         text,      -- VENDA, TRANSF_SAIDA, TRANSF_ENTRADA, RECEBIMENTO, AJUSTE_INVENTARIO, TROCA
  quantidade   int,       -- negativo = saída
  documento    text,
  dt_movimento timestamptz,
  usuario      text
);

-- Saídas por venda (só o último ano, igual a uma retenção de kardex on-line)
INSERT INTO varejo.movimentacoes_estoque (loja_id, produto_id, tipo, quantidade, documento, dt_movimento, usuario)
SELECT v.loja_id, i.produto_id, 'VENDA', -i.quantidade, 'CUPOM-' || v.id, v.data_hora, 'PDV'
FROM varejo.itens_venda i
JOIN varejo.vendas v ON v.id = i.venda_id
WHERE v.status = 'CONCLUIDA' AND v.data_hora >= now() - interval '365 days';

-- Saída na origem e entrada no destino das transferências
INSERT INTO varejo.movimentacoes_estoque (loja_id, produto_id, tipo, quantidade, documento, dt_movimento, usuario)
SELECT t.loja_origem, t.produto_id, 'TRANSF_SAIDA', -t.quantidade, 'TRF-' || t.id, t.dt_solicitacao, 'WMS'
FROM varejo.transferencias t WHERE t.status IN ('EM_TRANSITO', 'RECEBIDA')
UNION ALL
SELECT t.loja_destino, t.produto_id, 'TRANSF_ENTRADA', t.quantidade, 'TRF-' || t.id, t.dt_recebimento, 'LOJA'
FROM varejo.transferencias t WHERE t.status = 'RECEBIDA';

-- Recebimento de compras nos CDs
INSERT INTO varejo.movimentacoes_estoque (loja_id, produto_id, tipo, quantidade, documento, dt_movimento, usuario)
SELECT pc.cd_id, pi.produto_id, 'RECEBIMENTO', pi.qtd_recebida, 'PC-' || pc.id, pc.dt_recebimento, 'WMS'
FROM varejo.pedidos_compra_itens pi
JOIN varejo.pedidos_compra pc ON pc.id = pi.pedido_id
WHERE pi.qtd_recebida > 0 AND pc.dt_recebimento IS NOT NULL;

-- Ajustes de inventário e trocas
INSERT INTO varejo.movimentacoes_estoque (loja_id, produto_id, tipo, quantidade, documento, dt_movimento, usuario)
SELECT i.loja_id, ii.produto_id, 'AJUSTE_INVENTARIO', ii.qtd_contada - ii.qtd_sistema, 'INV-' || i.id, i.data_inventario + time '22:00', 'INVENTARIO'
FROM varejo.inventario_itens ii JOIN varejo.inventarios i ON i.id = ii.inventario_id
WHERE ii.qtd_contada <> ii.qtd_sistema
UNION ALL
SELECT loja_id, produto_id, 'TROCA', quantidade, 'TRC-' || id, dt_registro, 'PDV'
FROM varejo.trocas_devolucoes;

-- ---------------------------------------------------------------------
-- FISCAL: notas, itens e eventos na SEFAZ
-- ---------------------------------------------------------------------
CREATE SCHEMA fiscal;

CREATE TABLE fiscal.notas (
  id               bigserial PRIMARY KEY,
  chave_acesso     char(44),
  modelo           char(2),     -- 65 = NFC-e (venda), 55 = NF-e
  serie            int,
  numero           bigint,
  loja_id          int,
  tipo_operacao    text,        -- VENDA, TRANSF_SAIDA, TRANSF_ENTRADA, COMPRA, DEVOLUCAO
  dt_emissao       timestamptz,
  status           text,        -- AUTORIZADA, CANCELADA, REJEITADA, CONTINGENCIA, PENDENTE
  cod_status_sefaz int,         -- 100 autorizada, 135 cancelada, 2xx/7xx rejeição
  protocolo        text,
  valor_total      numeric(14,2),
  venda_id         bigint,
  transferencia_id bigint,
  pedido_compra_id bigint
);

-- Uma inserção só (sem UPDATE depois), para a tabela não nascer inchada.
-- Chave determinística (UF 35 + id): a carga consegue consultar por chave.
-- Rejeições espalhadas e, nas últimas 48h, algumas lojas em contingência/pendentes.
INSERT INTO fiscal.notas (id, chave_acesso, modelo, serie, numero, loja_id, tipo_operacao, dt_emissao, status,
                          cod_status_sefaz, protocolo, valor_total, venda_id, transferencia_id, pedido_compra_id)
SELECT id, '35' || lpad(id::text, 42, '0'), modelo, serie, numero, loja_id, tipo_operacao, dt_emissao, st,
       CASE st WHEN 'AUTORIZADA' THEN 100 WHEN 'CANCELADA' THEN 135
               WHEN 'REJEITADA' THEN (ARRAY[204, 225, 539, 778])[1 + floor(random() * 4)::int] END,
       CASE WHEN st IN ('AUTORIZADA', 'CANCELADA') THEN '135' || lpad(id::text, 12, '0') END,
       valor_total, venda_id, transferencia_id, pedido_compra_id
FROM (
  SELECT nextval('fiscal.notas_id_seq') AS id, n.*,
         CASE WHEN n.status0 = 'CANCELADA' THEN 'CANCELADA'
              WHEN n.tipo_operacao = 'VENDA' AND n.dt_emissao >= now() - interval '48 hours' AND n.loja_id % 23 = 0
                THEN CASE WHEN random() < 0.6 THEN 'CONTINGENCIA' ELSE 'PENDENTE' END
              WHEN random() < 0.004 THEN 'REJEITADA'
              ELSE 'AUTORIZADA' END AS st
  FROM (
    SELECT '65' AS modelo, 1 + (v.loja_id % 3) AS serie, v.id AS numero, v.loja_id, 'VENDA' AS tipo_operacao,
           v.data_hora + interval '2 seconds' AS dt_emissao, v.status AS status0, v.valor_total,
           v.id AS venda_id, NULL::bigint AS transferencia_id, NULL::bigint AS pedido_compra_id
    FROM varejo.vendas v
    UNION ALL
    SELECT '55', 10, t.id, t.loja_origem, 'TRANSF_SAIDA', t.dt_solicitacao, 'OK', 0, NULL, t.id, NULL
    FROM varejo.transferencias t WHERE t.status IN ('EM_TRANSITO', 'RECEBIDA')
    UNION ALL
    SELECT '55', 20, pc.id, pc.cd_id, 'COMPRA', pc.dt_recebimento, 'OK', pc.valor_total, NULL, NULL, pc.id
    FROM varejo.pedidos_compra pc WHERE pc.dt_recebimento IS NOT NULL
  ) n
) x;

CREATE TABLE fiscal.notas_itens (
  id             bigserial PRIMARY KEY,
  nota_id        bigint,
  item           int,
  produto_id     int,
  cfop           text,
  ncm            text,
  quantidade     int,
  valor_unitario numeric(10,2),
  valor_icms     numeric(10,2)
);

-- Itens das NFC-e de venda (um por item do cupom)
INSERT INTO fiscal.notas_itens (nota_id, item, produto_id, cfop, ncm, quantidade, valor_unitario, valor_icms)
SELECT n.id, row_number() OVER (PARTITION BY i.venda_id ORDER BY i.id), i.produto_id, '5102',
       CASE p.departamento WHEN 'CALCADOS' THEN '64029990' WHEN 'CASA' THEN '63026000' ELSE '62046200' END,
       i.quantidade, i.preco_unitario, round((i.quantidade * i.preco_unitario - i.desconto) * 0.18, 2)
FROM varejo.itens_venda i
JOIN fiscal.notas n    ON n.venda_id = i.venda_id
JOIN varejo.produtos p ON p.id = i.produto_id;

CREATE TABLE fiscal.eventos_sefaz (
  id                bigserial PRIMARY KEY,
  nota_id           bigint,
  tipo              text,     -- AUTORIZACAO, CANCELAMENTO, CONSULTA
  dt_evento         timestamptz,
  cod_retorno       int,
  tempo_resposta_ms int
);

INSERT INTO fiscal.eventos_sefaz (nota_id, tipo, dt_evento, cod_retorno, tempo_resposta_ms)
SELECT id, 'AUTORIZACAO', dt_emissao + interval '1 second', coalesce(cod_status_sefaz, 108),
       -- picos de lentidão da SEFAZ em datas de grande movimento
       (200 + random() * 600 + CASE WHEN extract(hour FROM dt_emissao) BETWEEN 18 AND 21 THEN random() * 1500 ELSE 0 END)::int
FROM fiscal.notas
UNION ALL
SELECT id, 'CANCELAMENTO', dt_emissao + interval '5 minutes', 135, (300 + random() * 900)::int
FROM fiscal.notas WHERE status = 'CANCELADA';

-- ---------------------------------------------------------------------
-- INTEGRACAO: eventos loja -> central (estilo réplica/fila de integração)
-- ---------------------------------------------------------------------
CREATE SCHEMA integracao;

CREATE TABLE integracao.eventos (
  id            bigserial PRIMARY KEY,
  loja_id       int,
  tipo_evento   text,      -- VENDA, ESTOQUE, PRECO, TRANSFERENCIA, NOTA
  chave         text,
  status        text,      -- PROCESSADO, PENDENTE, ERRO
  tentativas    int,
  criado_em     timestamptz,
  processado_em timestamptz,
  erro          text
);

-- Lojas com fila parada nas últimas 6h (link da loja caiu) e ~0,3% de erros de integração
INSERT INTO integracao.eventos (loja_id, tipo_evento, chave, status, tentativas, criado_em, processado_em, erro)
SELECT loja, tp, tp || '-' || g, st,
       CASE st WHEN 'ERRO' THEN 5 WHEN 'PENDENTE' THEN 0 ELSE 1 END,
       dt,
       CASE WHEN st = 'PROCESSADO' THEN dt + (0.5 + random() * 8) * interval '1 second' END,
       CASE WHEN st = 'ERRO' THEN (ARRAY['ORA-00001: chave duplicada no destino', 'timeout na conexao com a central',
                                         'SKU inexistente no cadastro central'])[1 + floor(random() * 3)::int] END
FROM (
  SELECT g, loja, tp, dt,
         CASE WHEN dt >= now() - interval '6 hours' AND loja % 17 = 0 THEN 'PENDENTE'
              WHEN random() < 0.003 THEN 'ERRO'
              ELSE 'PROCESSADO' END AS st
  FROM (
    SELECT g, 4 + floor(random() * 197)::int AS loja,
           (ARRAY['VENDA','VENDA','VENDA','ESTOQUE','ESTOQUE','PRECO','TRANSFERENCIA','NOTA'])[1 + floor(random() * 8)::int] AS tp,
           now() - random() * interval '30 days' AS dt
    FROM generate_series(1, pg_temp.n(3000000)) g
  ) a
) x;

GRANT USAGE ON SCHEMA fiscal, integracao TO monitor_user;
GRANT SELECT ON ALL TABLES IN SCHEMA varejo, fiscal, integracao TO monitor_user;

COMMIT;

-- ---------------------------------------------------------------------
-- Leitura para o monitor e estatísticas
-- ---------------------------------------------------------------------

ANALYZE varejo.vendas;
ANALYZE varejo.itens_venda;
ANALYZE varejo.fornecedores;
ANALYZE varejo.pedidos_compra;
ANALYZE varejo.pedidos_compra_itens;
ANALYZE varejo.trocas_devolucoes;
ANALYZE varejo.movimentacoes_estoque;
ANALYZE fiscal.notas;
ANALYZE fiscal.notas_itens;
ANALYZE fiscal.eventos_sefaz;
ANALYZE integracao.eventos;

SELECT n.nspname || '.' || c.relname AS tabela, c.reltuples::bigint AS linhas,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamanho
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname IN ('varejo', 'fiscal', 'integracao')
ORDER BY c.reltuples DESC;
