-- =====================================================================
-- E-commerce e APIs do app (MySQL) - base FICTÍCIA.
-- Clientes do site, pedidos (entrega, retira em loja e ship from store),
-- pagamentos, rastreio e carrinhos. Índices só nas PKs, de propósito.
-- Volume: ~7 milhões de linhas. Leva uns 2 minutos na primeira subida.
-- =====================================================================
CREATE DATABASE IF NOT EXISTS ecommerce;
USE ecommerce;
SET SESSION cte_max_recursion_depth = 3000000;

-- Sequência auxiliar de 1 a 1 milhão
CREATE TABLE seq (n INT PRIMARY KEY);
INSERT INTO seq
WITH RECURSIVE d(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM d WHERE n < 9)
SELECT 1 + a.n + 10 * b.n + 100 * c.n + 1000 * e.n + 10000 * f.n + 100000 * g.n
FROM d a, d b, d c, d e, d f, d g;

CREATE TABLE clientes (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  nome         VARCHAR(80),
  email        VARCHAR(120),
  uf           CHAR(2),
  origem       VARCHAR(20),         -- SITE, APP, LOJA
  dt_cadastro  DATETIME
);
INSERT INTO clientes (nome, email, uf, origem, dt_cadastro)
SELECT CONCAT(ELT(1 + FLOOR(RAND() * 8), 'Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Hugo'), ' ',
              ELT(1 + FLOOR(RAND() * 6), 'Silva','Souza','Oliveira','Santos','Lima','Costa')),
       CONCAT('app', n, '@exemplo.com'),
       ELT(1 + n % 8, 'SP','RJ','MG','RS','PR','BA','PE','CE'),
       ELT(1 + FLOOR(RAND() * 3), 'SITE','APP','LOJA'),
       NOW() - INTERVAL FLOOR(RAND() * 2000) DAY
FROM seq WHERE n <= 300000;

CREATE TABLE produtos_site (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  sku       VARCHAR(12),
  titulo    VARCHAR(120),
  categoria VARCHAR(30),
  preco     DECIMAL(10,2),
  ativo     TINYINT
);
INSERT INTO produtos_site (sku, titulo, categoria, preco, ativo)
SELECT CONCAT('SKU', LPAD(n, 6, '0')),
       CONCAT(ELT(1 + n % 12, 'Blusa','Vestido','Saia','Camisa','Bermuda','Calca','Conjunto','Pijama','Tenis','Sandalia','Bolsa','Toalha'), ' modelo ', n),
       ELT(1 + n % 6, 'FEMININO','MASCULINO','INFANTIL','CALCADOS','ACESSORIOS','CASA'),
       ROUND(29.90 + RAND() * 470, 2), RAND() > 0.08
FROM seq WHERE n <= 20000;
-- Problemas de schema de propósito (o monitor deve achar): índice duplicado e índice que ninguém usa
CREATE INDEX idx_produtos_categoria ON produtos_site (categoria);
CREATE INDEX idx_produtos_categoria_2 ON produtos_site (categoria);
CREATE INDEX idx_produtos_preco ON produtos_site (preco);

CREATE TABLE pedidos (
  id               BIGINT AUTO_INCREMENT PRIMARY KEY,
  cliente_id       INT,
  dt_pedido        DATETIME,
  status           VARCHAR(25),    -- CRIADO, PAGO, EM_SEPARACAO, ENVIADO, ENTREGUE, AGUARDANDO_RETIRADA, RETIRADO, CANCELADO
  modalidade       VARCHAR(20),    -- ENTREGA, RETIRA_LOJA, SHIP_FROM_STORE
  loja_atendimento INT,
  valor_total      DECIMAL(12,2),
  frete            DECIMAL(10,2),
  cupom            VARCHAR(20)
);
INSERT INTO pedidos (cliente_id, dt_pedido, status, modalidade, loja_atendimento, valor_total, frete, cupom)
SELECT cli, dt, CASE
         WHEN dt > NOW() - INTERVAL 1 DAY  THEN ELT(1 + FLOOR(RAND() * 3), 'CRIADO','PAGO','EM_SEPARACAO')
         WHEN modal = 'RETIRA_LOJA' THEN IF(RAND() < 0.9, 'RETIRADO', IF(RAND() < 0.5, 'AGUARDANDO_RETIRADA', 'CANCELADO'))
         ELSE IF(RAND() < 0.92, 'ENTREGUE', ELT(1 + FLOOR(RAND() * 3), 'ENVIADO','CANCELADO','EM_SEPARACAO')) END,
       modal, 4 + FLOOR(RAND() * 197), 0,
       IF(modal = 'ENTREGA', ROUND(9.90 + RAND() * 30, 2), 0),
       IF(RAND() < 0.15, ELT(1 + FLOOR(RAND() * 4), 'BEMVINDO10','FRETEGRATIS','APP15','BLACK30'), NULL)
FROM (SELECT 1 + FLOOR(RAND() * 300000) AS cli,
             NOW() - INTERVAL FLOOR(RAND() * 365 * 24 * 60) MINUTE AS dt,
             ELT(1 + FLOOR(RAND() * 10), 'ENTREGA','ENTREGA','ENTREGA','ENTREGA','ENTREGA','RETIRA_LOJA','RETIRA_LOJA','RETIRA_LOJA','SHIP_FROM_STORE','SHIP_FROM_STORE') AS modal
      FROM seq a JOIN (SELECT 0 AS k UNION ALL SELECT 1) b WHERE a.n <= 300000) x;

CREATE TABLE pedido_itens (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  pedido_id  BIGINT,
  sku        VARCHAR(12),
  quantidade INT,
  preco      DECIMAL(10,2)
);
INSERT INTO pedido_itens (pedido_id, sku, quantidade, preco)
SELECT p.id, CONCAT('SKU', LPAD(1 + FLOOR(RAND() * 20000), 6, '0')), 1 + FLOOR(RAND() * 2), ROUND(29.90 + RAND() * 470, 2)
FROM pedidos p JOIN seq s ON s.n <= 1 + p.id % 4;
UPDATE pedidos p JOIN (SELECT pedido_id, SUM(quantidade * preco) v FROM pedido_itens GROUP BY pedido_id) t ON t.pedido_id = p.id
SET p.valor_total = t.v + p.frete;

CREATE TABLE pagamentos (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  pedido_id       BIGINT,
  meio            VARCHAR(20),     -- CARTAO_CREDITO, PIX, CARTAO_LOJA, BOLETO
  status          VARCHAR(20),     -- APROVADO, RECUSADO, PENDENTE, ESTORNADO
  valor           DECIMAL(12,2),
  dt_criacao      DATETIME,
  dt_autorizacao  DATETIME,
  nsu             VARCHAR(20)
);
INSERT INTO pagamentos (pedido_id, meio, status, valor, dt_criacao, dt_autorizacao, nsu)
SELECT id, meio, st, valor_total, dt_pedido, IF(st = 'APROVADO', dt_pedido + INTERVAL FLOOR(1 + RAND() * 40) SECOND, NULL),
       IF(st = 'APROVADO', LPAD(FLOOR(RAND() * 999999999), 12, '0'), NULL)
FROM (SELECT id, valor_total, dt_pedido,
             ELT(1 + FLOOR(RAND() * 5), 'CARTAO_CREDITO','CARTAO_CREDITO','PIX','CARTAO_LOJA','BOLETO') AS meio,
             CASE WHEN status = 'CANCELADO' THEN IF(RAND() < 0.5, 'RECUSADO', 'ESTORNADO')
                  WHEN status = 'CRIADO' THEN 'PENDENTE'
                  ELSE 'APROVADO' END AS st
      FROM pedidos) x;

CREATE TABLE rastreio_eventos (
  id            BIGINT AUTO_INCREMENT PRIMARY KEY,
  pedido_id     BIGINT,
  evento        VARCHAR(40),
  transportadora VARCHAR(30),
  dt_evento     DATETIME
);
INSERT INTO rastreio_eventos (pedido_id, evento, transportadora, dt_evento)
SELECT p.id, ELT(s.n, 'PEDIDO_RECEBIDO','PAGAMENTO_APROVADO','EM_SEPARACAO','NOTA_EMITIDA','COLETADO','EM_ROTA','ENTREGUE'),
       IF(p.modalidade = 'RETIRA_LOJA', 'LOJA', ELT(1 + p.id % 3, 'TRANSP_A','TRANSP_B','CORREIOS')),
       p.dt_pedido + INTERVAL (s.n - 1) * (2 + p.id % 20) HOUR
FROM pedidos p JOIN seq s ON s.n <= CASE p.status WHEN 'ENTREGUE' THEN 7 WHEN 'RETIRADO' THEN 4 WHEN 'ENVIADO' THEN 6
                                                  WHEN 'CANCELADO' THEN 1 WHEN 'CRIADO' THEN 1 ELSE 3 END;

CREATE TABLE carrinhos (
  id            BIGINT AUTO_INCREMENT PRIMARY KEY,
  cliente_id    INT,
  status        VARCHAR(15),     -- ABERTO, CONVERTIDO, EXPIRADO
  criado_em     DATETIME,
  atualizado_em DATETIME
);
INSERT INTO carrinhos (cliente_id, status, criado_em, atualizado_em)
SELECT 1 + FLOOR(RAND() * 300000), ELT(1 + FLOOR(RAND() * 4), 'ABERTO','CONVERTIDO','CONVERTIDO','EXPIRADO'), dt, dt + INTERVAL FLOOR(RAND() * 600) MINUTE
FROM (SELECT NOW() - INTERVAL FLOOR(RAND() * 60 * 24 * 60) MINUTE AS dt FROM seq WHERE n <= 250000) x;

CREATE TABLE carrinho_itens (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  carrinho_id BIGINT,
  sku         VARCHAR(12),
  quantidade  INT,
  adicionado_em DATETIME
);
INSERT INTO carrinho_itens (carrinho_id, sku, quantidade, adicionado_em)
SELECT c.id, CONCAT('SKU', LPAD(1 + FLOOR(RAND() * 20000), 6, '0')), 1, c.criado_em
FROM carrinhos c JOIN seq s ON s.n <= 1 + c.id % 3;

-- Tabela sem chave primária, de propósito (log de integração com o ERP)
CREATE TABLE log_integracao_erp (
  pedido_id  BIGINT,
  mensagem   VARCHAR(200),
  criado_em  DATETIME
);
INSERT INTO log_integracao_erp
SELECT id, 'pedido enviado ao ERP', dt_pedido + INTERVAL 1 MINUTE FROM pedidos WHERE id % 5 = 0;

DROP TABLE seq;
ANALYZE TABLE clientes, produtos_site, pedidos, pedido_itens, pagamentos, rastreio_eventos, carrinhos, carrinho_itens, log_integracao_erp;
