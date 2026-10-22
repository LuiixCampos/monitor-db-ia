-- =====================================================================
-- Monitor acompanhando a base ampliada (schemas fiscal e integracao).
-- Idempotente.
-- =====================================================================

-- Top lentas: mais espaço na fila (8) agora que há mais sistemas no banco
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
  AND s.query NOT ILIKE '%to_regclass%'
  AND s.query ILIKE 'SELECT%'
  AND s.mean_exec_time > 20
ORDER BY s.mean_exec_time DESC
LIMIT 8;

-- Histórico (Databricks / previsão) passa a incluir as queries dos novos schemas
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
  WHERE o.atualizado_em > now() - interval '1 hour'
    AND o.calls >= 3
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$fn$;

GRANT SELECT ON monitor.vw_top_lentas TO monitor_user;
