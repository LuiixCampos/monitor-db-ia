-- Ignora as consultas de carga do Power BI/Grafana sobre o schema bi.
-- Elas leem tabelas inteiras de propósito e não são "queries lentas" da aplicação.
CREATE OR REPLACE VIEW monitor.vw_top_lentas AS
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
  AND s.toplevel
  AND s.query NOT ILIKE '%pg_stat_statements%'
  AND s.query NOT ILIKE '%monitor.%'
  AND s.query NOT ILIKE '%"bi".%'
  AND s.query NOT ILIKE '% bi.%'
  AND s.query ILIKE 'SELECT%'
  AND s.mean_exec_time > 20
ORDER BY s.mean_exec_time DESC
LIMIT 5;
