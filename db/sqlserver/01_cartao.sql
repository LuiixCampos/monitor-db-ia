-- =====================================================================
-- Cartão próprio e crediário (SQL Server) - base FICTÍCIA.
-- Contas, cartões, transações (loja, e-commerce e fora), faturas,
-- pagamentos e régua de cobrança. Índices só nas PKs, de propósito.
-- Volume: ~8 milhões de linhas.
-- =====================================================================
SET NOCOUNT ON;
CREATE DATABASE cartao;
GO
ALTER DATABASE cartao SET RECOVERY SIMPLE;
GO
USE cartao;
GO
CREATE SCHEMA fin;
GO

-- Tabela de números 1..4.000.000
SELECT TOP (4000000) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) AS n
INTO #n
FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c;
CREATE UNIQUE CLUSTERED INDEX ix ON #n (n);

-- Contas do cartão (cliente_ref = id do cliente no varejo)
CREATE TABLE fin.contas (
  id                int IDENTITY PRIMARY KEY,
  cliente_ref       int,
  limite_total      decimal(12,2),
  limite_disponivel decimal(12,2),
  status            varchar(15),     -- ATIVA, BLOQUEADA, CANCELADA
  dia_vencimento    tinyint,
  faixa_score       char(1),         -- A a E
  dt_abertura       date
);
-- Os valores aleatórios são gravados antes numa tabela temporária: o SQL Server
-- pode recalcular NEWID() a cada referência, e isso deixaria a base incoerente.
SELECT n, CAST(300 + ABS(CHECKSUM(NEWID()) % 5700) AS decimal(12,2)) AS lim,
       ABS(CHECKSUM(NEWID()) % 80) AS uso, ABS(CHECKSUM(NEWID()) % 100) AS r,
       ABS(CHECKSUM(NEWID()) % 5) AS score, ABS(CHECKSUM(NEWID()) % 3000) AS idade
INTO #c FROM #n WHERE n <= 120000;

INSERT INTO fin.contas (cliente_ref, limite_total, limite_disponivel, status, dia_vencimento, faixa_score, dt_abertura)
SELECT n, lim, CAST(lim * (0.2 + uso / 100.0) AS decimal(12,2)),
       CASE WHEN r < 90 THEN 'ATIVA' WHEN r < 96 THEN 'BLOQUEADA' ELSE 'CANCELADA' END,
       CAST(CHOOSE(1 + n % 4, 5, 10, 15, 25) AS tinyint), CHAR(65 + score),
       DATEADD(day, -idade, CAST(GETDATE() AS date))
FROM #c ORDER BY n;
DROP TABLE #c;

CREATE TABLE fin.cartoes (
  id         int IDENTITY PRIMARY KEY,
  conta_id   int,
  final      char(4),
  tipo       varchar(15),     -- PRIVATE_LABEL, BANDEIRADO
  status     varchar(15),     -- ATIVO, BLOQUEADO, CANCELADO
  validade   date
);
INSERT INTO fin.cartoes (conta_id, final, tipo, status, validade)
SELECT c.id, RIGHT('000' + CAST(ABS(CHECKSUM(NEWID()) % 10000) AS varchar(4)), 4),
       CASE WHEN k.n = 1 THEN 'PRIVATE_LABEL' ELSE 'BANDEIRADO' END,
       CASE c.status WHEN 'ATIVA' THEN 'ATIVO' WHEN 'BLOQUEADA' THEN 'BLOQUEADO' ELSE 'CANCELADO' END,
       DATEADD(month, 6 + ABS(CHECKSUM(NEWID()) % 60), CAST(GETDATE() AS date))
FROM fin.contas c JOIN #n k ON k.n <= 1 + c.id % 2;

-- Transações dos últimos 12 meses
CREATE TABLE fin.transacoes (
  id               bigint IDENTITY PRIMARY KEY,
  conta_id         int,
  cartao_id        int,
  dt_transacao     datetime2(0),
  valor            decimal(12,2),
  parcelas         tinyint,
  canal            varchar(15),     -- LOJA, ECOMMERCE, EXTERNO
  loja_id          int,
  status           varchar(15),     -- APROVADA, NEGADA, ESTORNADA
  motivo_negativa  varchar(30),
  mcc              char(4)
);
SELECT n,
       1 + ABS(CHECKSUM(NEWID()) % 180000) AS cartao,
       DATEADD(second, -(ABS(CHECKSUM(NEWID()) % 31536000)), SYSDATETIME()) AS dt,
       CAST(19.90 + (ABS(CHECKSUM(NEWID()) % 60000)) / 100.0 AS decimal(12,2)) AS valor,
       CAST(CHOOSE(1 + ABS(CHECKSUM(NEWID()) % 6), 1, 1, 2, 3, 5, 10) AS tinyint) AS parcelas,
       CAST(CHOOSE(1 + ABS(CHECKSUM(NEWID()) % 5), 'LOJA', 'LOJA', 'LOJA', 'ECOMMERCE', 'EXTERNO') AS varchar(15)) AS canal,
       ABS(CHECKSUM(NEWID()) % 100) AS r,
       4 + ABS(CHECKSUM(NEWID()) % 197) AS loja,
       ABS(CHECKSUM(NEWID()) % 4) AS k
INTO #t FROM #n WHERE n <= 4000000;

INSERT INTO fin.transacoes (conta_id, cartao_id, dt_transacao, valor, parcelas, canal, loja_id, status, motivo_negativa, mcc)
SELECT ct.conta_id, ct.id, x.dt, x.valor, x.parcelas, x.canal,
       CASE WHEN x.canal = 'LOJA' THEN x.loja END,
       CASE WHEN x.r < 92 THEN 'APROVADA' WHEN x.r < 98 THEN 'NEGADA' ELSE 'ESTORNADA' END,
       CASE WHEN x.r BETWEEN 92 AND 97 THEN CHOOSE(1 + x.k, 'SALDO_INSUFICIENTE', 'CARTAO_BLOQUEADO', 'SUSPEITA_FRAUDE', 'SENHA_INVALIDA') END,
       CASE WHEN x.canal = 'EXTERNO' THEN CHOOSE(1 + x.k, '5411', '5812', '5541', '4121') ELSE '5651' END
FROM #t x
JOIN fin.cartoes ct ON ct.id = x.cartao
ORDER BY x.n;
DROP TABLE #t;

-- Faturas mensais dos últimos 12 meses
CREATE TABLE fin.faturas (
  id            bigint IDENTITY PRIMARY KEY,
  conta_id      int,
  competencia   date,
  dt_vencimento date,
  valor_total   decimal(12,2),
  valor_minimo  decimal(12,2),
  valor_pago    decimal(12,2),
  status        varchar(15),     -- PAGA, PARCIAL, ATRASADA, ABERTA
  dt_pagamento  date
);
SELECT c.id AS conta_id, c.dia_vencimento, c.faixa_score, m.n AS mes,
       DATEADD(month, -m.n, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)) AS comp,
       CAST(50 + (ABS(CHECKSUM(NEWID()) % 150000)) / 100.0 AS decimal(12,2)) AS v,
       ABS(CHECKSUM(NEWID()) % 100) AS r
INTO #f FROM fin.contas c JOIN #n m ON m.n <= 12;

INSERT INTO fin.faturas (conta_id, competencia, dt_vencimento, valor_total, valor_minimo, valor_pago, status, dt_pagamento)
SELECT conta_id, comp, DATEADD(day, dia_vencimento - 1, DATEADD(month, 1, comp)), v, ROUND(v * 0.15, 2),
       CASE st WHEN 'PAGA' THEN v WHEN 'PARCIAL' THEN ROUND(v * 0.4, 2) ELSE 0 END, st,
       CASE WHEN st IN ('PAGA', 'PARCIAL') THEN DATEADD(day, dia_vencimento - 3, DATEADD(month, 1, comp)) END
FROM #f
CROSS APPLY (SELECT CASE WHEN mes = 1 AND r < 60 THEN 'ABERTA'
                         WHEN faixa_score IN ('D', 'E') AND r < 35 THEN 'ATRASADA'
                         WHEN r < 6 THEN 'ATRASADA'
                         WHEN r < 14 THEN 'PARCIAL'
                         ELSE 'PAGA' END AS st) s
ORDER BY conta_id, mes DESC;
DROP TABLE #f;

CREATE TABLE fin.pagamentos (
  id            bigint IDENTITY PRIMARY KEY,
  fatura_id     bigint,
  dt_pagamento  datetime2(0),
  valor         decimal(12,2),
  canal         varchar(20)     -- BOLETO, PIX, LOJA, DEBITO_AUTOMATICO
);
INSERT INTO fin.pagamentos (fatura_id, dt_pagamento, valor, canal)
SELECT id, DATEADD(minute, ABS(CHECKSUM(NEWID()) % 1440), CAST(dt_pagamento AS datetime2(0))), valor_pago,
       CHOOSE(1 + ABS(CHECKSUM(NEWID()) % 4), 'BOLETO', 'PIX', 'LOJA', 'DEBITO_AUTOMATICO')
FROM fin.faturas WHERE valor_pago > 0;

-- Régua de cobrança: tabela sem chave primária (heap), de propósito
CREATE TABLE fin.cobranca_eventos (
  conta_id  int,
  fatura_id bigint,
  acao      varchar(20),     -- SMS, EMAIL, LIGACAO, NEGATIVACAO
  dt_evento datetime2(0)
);
INSERT INTO fin.cobranca_eventos (conta_id, fatura_id, acao, dt_evento)
SELECT f.conta_id, f.id, CHOOSE(k.n, 'SMS', 'EMAIL', 'LIGACAO', 'NEGATIVACAO'), DATEADD(day, k.n * 7, CAST(f.dt_vencimento AS datetime2(0)))
FROM fin.faturas f JOIN #n k ON k.n <= 4
WHERE f.status = 'ATRASADA';

-- Índice duplicado e índice sem uso, de propósito (o monitor deve achar)
CREATE INDEX ix_contas_status ON fin.contas (status);
CREATE INDEX ix_contas_status_2 ON fin.contas (status);
CREATE INDEX ix_cartoes_validade ON fin.cartoes (validade);

DROP TABLE #n;
UPDATE STATISTICS fin.contas;
UPDATE STATISTICS fin.cartoes;
UPDATE STATISTICS fin.transacoes;
UPDATE STATISTICS fin.faturas;
UPDATE STATISTICS fin.pagamentos;
GO

-- Usuário de monitoramento: DMVs, planos e leitura
USE master;
GO
CREATE LOGIN monitor_user WITH PASSWORD = '$(MONITOR_PASSWORD)', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO monitor_user;
GO
USE cartao;
GO
CREATE USER monitor_user FOR LOGIN monitor_user;
GRANT SELECT, SHOWPLAN, VIEW DATABASE STATE, VIEW DEFINITION TO monitor_user;
GO
