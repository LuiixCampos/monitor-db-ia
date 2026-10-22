-- =====================================================================
-- Monitor multibanco: MySQL, SQL Server e MongoDB entram no mesmo ciclo
-- (coleta -> pistas -> IA -> chamado -> HML/PRD -> histórico).
-- O coletor (scripts/coletor_multibanco.py) grava aqui as queries lentas
-- de cada banco e os achados de saúde do schema de todos eles.
-- Idempotente.
-- =====================================================================

-- Cada banco é um "sistema" da varejista fictícia
INSERT INTO monitor.ambientes (ambiente, banco, host, porta, nome_banco, papel, coletar, testar_correcoes, aplicar_correcoes) VALUES
  ('PRD', 'MYSQL',     'mysql-lab',     3306,  'ecommerce', 'E-commerce e APIs do app (MySQL). Sem HML no lab.',                 true, false, true),
  ('PRD', 'SQLSERVER', 'sqlserver-lab', 1433,  'cartao',    'Cartão próprio e crediário (SQL Server). Sem HML no lab.',         true, false, true),
  ('PRD', 'MONGODB',   'mongo-lab',     27017, 'app',       'Catálogo, avaliações e navegação do app (MongoDB). Sem HML no lab.', true, false, true)
ON CONFLICT DO NOTHING;

-- Queries lentas dos outros bancos (Oracle continua em monitor.oracle_lentas)
CREATE TABLE IF NOT EXISTS monitor.lentas (
  banco         text,
  ambiente      text DEFAULT 'PRD',
  query_id      text,          -- digest (MySQL), query_hash (SQL Server), queryHash (MongoDB)
  query         text,
  calls         bigint,
  mean_exec_ms  numeric,
  plano         text,
  pistas        text,
  atualizado_em timestamptz DEFAULT now(),
  PRIMARY KEY (banco, ambiente, query_id)
);

-- Fila do analisador multibanco: lentas sem análise nas últimas 24h
CREATE OR REPLACE VIEW monitor.vw_lentas_pendentes AS
SELECT l.*
FROM monitor.lentas l
WHERE l.atualizado_em > now() - interval '1 hour'
  AND l.mean_exec_ms > 20
  AND NOT EXISTS (
    SELECT 1 FROM monitor.analises_ia a
    WHERE a.banco = l.banco AND a.sql_id = l.query_id
      AND a.analisado_em > now() - interval '24 hours')
ORDER BY l.mean_exec_ms DESC
LIMIT 5;

-- Saúde do schema: índices sem uso, duplicados, tabelas sem PK e maiores tabelas
CREATE TABLE IF NOT EXISTS monitor.saude_schema (
  banco       text,
  ambiente    text DEFAULT 'PRD',
  tipo        text,      -- INDICE_SEM_USO, INDICE_DUPLICADO, SEM_PK, MAIOR_TABELA
  objeto      text,
  detalhe     text,
  tamanho_mb  numeric,
  coletado_em timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_saude_schema_banco ON monitor.saude_schema (banco, ambiente);

-- Saúde do schema do próprio PostgreSQL (o coletor grava o resultado em monitor.saude_schema)
CREATE OR REPLACE VIEW monitor.vw_saude_postgres AS
WITH idx AS (
  SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan, i.indrelid, i.indkey::text AS cols,
         i.indisprimary, i.indisunique, pg_relation_size(s.indexrelid) AS bytes
  FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
  WHERE s.schemaname IN ('varejo', 'fiscal', 'integracao')
)
SELECT 'INDICE_SEM_USO' AS tipo, schemaname || '.' || indexrelname AS objeto,
       'nenhuma leitura desde o último reset das estatísticas (tabela ' || relname || ')' AS detalhe,
       round(bytes / 1048576.0, 1) AS tamanho_mb
FROM idx WHERE idx_scan = 0 AND NOT indisprimary AND NOT indisunique
UNION ALL
SELECT 'INDICE_DUPLICADO', a.schemaname || '.' || a.indexrelname,
       'mesmas colunas de ' || b.indexrelname, round(a.bytes / 1048576.0, 1)
FROM idx a JOIN idx b ON a.indrelid = b.indrelid AND a.cols = b.cols AND a.indexrelname > b.indexrelname
UNION ALL
SELECT 'SEM_PK', n.nspname || '.' || c.relname, 'tabela sem chave primária', round(pg_total_relation_size(c.oid) / 1048576.0, 1)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname IN ('varejo', 'fiscal', 'integracao')
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')
UNION ALL
SELECT * FROM (
  SELECT 'MAIOR_TABELA', n.nspname || '.' || c.relname, c.reltuples::bigint || ' linhas',
         round(pg_total_relation_size(c.oid) / 1048576.0, 1)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname IN ('varejo', 'fiscal', 'integracao')
  ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 5) t;

-- Histórico para a previsão inclui os outros bancos
CREATE OR REPLACE FUNCTION monitor.fn_snapshot() RETURNS integer
LANGUAGE plpgsql AS $fn$
DECLARE
  n integer;
  t timestamptz := date_trunc('minute', now());
BEGIN
  INSERT INTO monitor.snapshots (coleta_em, banco, query_id, query, calls, mean_exec_ms, total_exec_ms)
  SELECT t, 'POSTGRES', s.queryid::text, left(s.query, 500), s.calls,
         round(s.mean_exec_time::numeric, 2), round(s.total_exec_time::numeric, 2)
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid
  WHERE d.datname = current_database() AND s.toplevel
    AND s.query ILIKE 'SELECT%' AND s.query ~* '(varejo|fiscal|integracao)\.' AND s.calls >= 3
    AND s.query NOT ILIKE '%monitor.%'
  UNION ALL
  SELECT t, 'ORACLE', o.sql_id, left(o.query, 500), o.calls, o.mean_exec_ms, o.mean_exec_ms * o.calls
  FROM monitor.oracle_lentas o
  WHERE o.atualizado_em > now() - interval '1 hour' AND o.calls >= 3
  UNION ALL
  SELECT t, l.banco, l.query_id, left(l.query, 500), l.calls, l.mean_exec_ms, l.mean_exec_ms * l.calls
  FROM monitor.lentas l
  WHERE l.atualizado_em > now() - interval '1 hour' AND l.calls >= 3 AND l.ambiente = 'PRD'
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$fn$;

-- Nome do banco no título do chamado
CREATE OR REPLACE FUNCTION monitor.fn_nome_banco(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE upper(coalesce(p, 'POSTGRES'))
           WHEN 'POSTGRES' THEN 'PostgreSQL' WHEN 'ORACLE' THEN 'Oracle' WHEN 'MYSQL' THEN 'MySQL'
           WHEN 'SQLSERVER' THEN 'SQL Server' WHEN 'MONGODB' THEN 'MongoDB' ELSE p END
$$;

CREATE OR REPLACE FUNCTION monitor.fn_abrir_chamados()
RETURNS TABLE (numero text, prioridade text, titulo text, mean_exec_ms numeric, calls bigint, query text, analise text)
LANGUAGE sql AS $fn$
  WITH novos AS (
    INSERT INTO monitor.chamados (analise_id, titulo, prioridade)
    SELECT a.id,
           coalesce(a.ambiente, 'PRD') || ' | ' || monitor.fn_nome_banco(a.banco)
             || ' - query lenta: ' || round(a.mean_exec_ms) || ' ms em média',
           CASE WHEN a.mean_exec_ms >= 150 THEN 'ALTA'
                WHEN a.mean_exec_ms >= 50  THEN 'MEDIA'
                ELSE 'BAIXA' END
    FROM monitor.analises_ia a
    WHERE a.analise IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM monitor.chamados c WHERE c.analise_id = a.id)
    RETURNING *
  )
  SELECT n.numero, n.prioridade, n.titulo, a.mean_exec_ms, a.calls,
         left(coalesce(a.query_texto,
                       (SELECT s.query FROM pg_stat_statements s
                        WHERE s.queryid = a.queryid ORDER BY s.toplevel DESC LIMIT 1), '?'), 400),
         left(a.analise, 2500)
  FROM novos n
  JOIN monitor.analises_ia a ON a.id = n.analise_id
  ORDER BY a.mean_exec_ms DESC;
$fn$;

-- BI / Grafana
CREATE OR REPLACE VIEW bi.mon_lentas AS
SELECT banco, ambiente, query_id, left(query, 300) AS query, calls, mean_exec_ms, atualizado_em FROM monitor.lentas
UNION ALL
SELECT 'ORACLE', 'PRD', sql_id, left(query, 300), calls, mean_exec_ms, atualizado_em FROM monitor.oracle_lentas;

CREATE OR REPLACE VIEW bi.mon_saude_schema AS
SELECT banco, ambiente, tipo, objeto, detalhe, tamanho_mb, coletado_em FROM monitor.saude_schema;

GRANT SELECT, INSERT, UPDATE, DELETE ON monitor.lentas, monitor.saude_schema TO monitor_user;
GRANT SELECT ON monitor.vw_lentas_pendentes, monitor.vw_saude_postgres, bi.mon_lentas, bi.mon_saude_schema TO monitor_user;
