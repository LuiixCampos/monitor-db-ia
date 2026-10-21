-- Schema de monitoramento: histórico das queries lentas e view para o n8n
CREATE SCHEMA monitor;

CREATE TABLE monitor.snapshot_queries (
  coleta_em        timestamptz DEFAULT now(),
  queryid          bigint,
  query            text,
  calls            bigint,
  total_exec_ms    numeric,
  mean_exec_ms     numeric,
  rows             bigint,
  shared_blks_read bigint,
  shared_blks_hit  bigint
);

CREATE VIEW monitor.vw_top_lentas AS
SELECT s.queryid,
       s.query,
       s.calls,
       round(s.total_exec_time::numeric, 2) AS total_exec_ms,
       round(s.mean_exec_time::numeric, 2)  AS mean_exec_ms,
       s.rows,
       s.shared_blks_read,
       s.shared_blks_hit
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid
WHERE d.datname = current_database()
  AND s.query NOT ILIKE '%pg_stat_statements%'
  AND s.query NOT ILIKE '%monitor.%'
  AND s.query ILIKE 'SELECT%'      -- ignora carga inicial (INSERT, ANALYZE, DDL)
  AND s.mean_exec_time > 20    -- só o que passa de 20 ms em média
ORDER BY s.mean_exec_time DESC
LIMIT 5;

GRANT USAGE ON SCHEMA monitor, loja TO monitor_user;
GRANT SELECT ON monitor.vw_top_lentas TO monitor_user;
GRANT SELECT, INSERT ON monitor.snapshot_queries TO monitor_user;
GRANT SELECT ON ALL TABLES IN SCHEMA loja TO monitor_user;  -- para o EXPLAIN na etapa 2
