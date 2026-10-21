-- =====================================================================
-- Histórico de performance para o Databricks.
-- monitor.snapshots guarda, a cada hora, o tempo médio de cada query
-- (Postgres via pg_stat_statements, Oracle via monitor.oracle_lentas).
-- fn_simular_historico gera dias anteriores SIMULADOS (origem = 'SIMULADO')
-- só para demonstrar a previsão; nunca se mistura com o coletado (REAL).
-- Idempotente.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitor.snapshots (
  coleta_em     timestamptz,
  banco         text,
  query_id      text,
  query         text,
  calls         bigint,
  mean_exec_ms  numeric,
  total_exec_ms numeric,
  origem        text DEFAULT 'REAL',
  PRIMARY KEY (coleta_em, banco, query_id)
);

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
    AND s.query ILIKE 'SELECT%' AND s.query ILIKE '%varejo.%' AND s.calls >= 3
  UNION ALL
  SELECT t, 'ORACLE', o.sql_id, left(o.query, 500), o.calls, o.mean_exec_ms, o.mean_exec_ms * o.calls
  FROM monitor.oracle_lentas o
  WHERE o.atualizado_em > now() - interval '1 hour'
    AND o.calls >= 3          -- ignora cursores de execução única (literais sem bind)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$fn$;

-- Gera p_dias de histórico simulado (uma amostra a cada 6h) para as queries
-- já capturadas, com degradação gradual (tabelas crescendo) e ruído.
CREATE OR REPLACE FUNCTION monitor.fn_simular_historico(p_dias int DEFAULT 60) RETURNS integer
LANGUAGE plpgsql AS $fn$
DECLARE n integer;
BEGIN
  DELETE FROM monitor.snapshots WHERE origem = 'SIMULADO';
  INSERT INTO monitor.snapshots (coleta_em, banco, query_id, query, calls, mean_exec_ms, total_exec_ms, origem)
  SELECT ts, b.banco, b.query_id, b.query,
         greatest(1, (b.calls * (1 - k))::bigint),
         round((b.mean_exec_ms * (0.55 + 0.45 * (1 - k)) * (0.9 + random() * 0.2))::numeric, 2),
         NULL, 'SIMULADO'
  FROM (SELECT DISTINCT ON (banco, query_id) banco, query_id, query, calls, mean_exec_ms
        FROM monitor.snapshots WHERE origem = 'REAL' AND calls >= 3
        ORDER BY banco, query_id, coleta_em DESC) b
  CROSS JOIN LATERAL (
    SELECT g AS ts, (extract(epoch FROM now() - g) / (p_dias * 86400.0))::numeric AS k
    FROM generate_series(now() - make_interval(days => p_dias), now() - interval '6 hours', interval '6 hours') g
  ) x
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$fn$;

-- Exportação: cada view devolve um único texto JSON (payload) para o n8n
CREATE OR REPLACE VIEW monitor.vw_export_snapshots AS
SELECT coalesce(json_agg(json_build_object(
         'coleta_em', to_char(coleta_em AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'banco', banco, 'query_id', query_id, 'query', query, 'calls', calls,
         'mean_exec_ms', mean_exec_ms, 'origem', origem))::text, '[]') AS payload,
       count(*) AS linhas
FROM monitor.snapshots;

CREATE OR REPLACE VIEW monitor.vw_export_chamados AS
SELECT coalesce(json_agg(json_build_object(
         'numero', c.numero, 'jira_key', c.jira_key, 'banco', coalesce(a.banco, 'POSTGRES'),
         'prioridade', c.prioridade, 'status', c.status, 'mean_exec_ms', a.mean_exec_ms,
         'aberto_em', to_char(c.aberto_em AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'resolvido_em', to_char(c.resolvido_em AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'antes_ms', k.antes_ms, 'depois_ms', k.depois_ms, 'ganho_pct', k.ganho_pct))::text, '[]') AS payload,
       count(*) AS linhas
FROM monitor.chamados c
LEFT JOIN monitor.analises_ia a ON a.id = c.analise_id
LEFT JOIN LATERAL (SELECT * FROM monitor.correcoes x WHERE x.jira_key = c.jira_key AND x.resultado = 'OK'
                   ORDER BY x.aplicado_em DESC LIMIT 1) k ON true;

GRANT SELECT, INSERT, DELETE ON monitor.snapshots TO monitor_user;
GRANT SELECT ON monitor.vw_export_snapshots, monitor.vw_export_chamados TO monitor_user;
