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

GRANT USAGE ON SCHEMA monitor, varejo TO monitor_user;
GRANT SELECT ON monitor.vw_top_lentas TO monitor_user;
GRANT SELECT, INSERT ON monitor.snapshot_queries TO monitor_user;
GRANT SELECT ON ALL TABLES IN SCHEMA varejo TO monitor_user;  -- para o EXPLAIN na etapa 2

-- Gera o plano de execução (sem executar a query) a partir do texto normalizado
-- do pg_stat_statements. GENERIC_PLAN (PG16+) aceita os parâmetros $1, $2...
CREATE FUNCTION monitor.fn_explain(p_query text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  r     record;
  plano text := '';
BEGIN
  -- O pg_stat_statements normaliza  interval '1 day'  para  interval $1,
  -- que não é sintaxe válida. Converte para $1::interval antes do EXPLAIN.
  p_query := regexp_replace(p_query, 'interval\s+(\$\d+)', '\1::interval', 'gi');
  FOR r IN EXECUTE 'EXPLAIN (GENERIC_PLAN) ' || p_query LOOP
    plano := plano || r."QUERY PLAN" || E'\n';
  END LOOP;
  RETURN plano;
EXCEPTION WHEN others THEN
  RETURN 'Erro no EXPLAIN: ' || SQLERRM;
END
$fn$;

-- Histórico das análises feitas pela IA
CREATE TABLE monitor.analises_ia (
  id           bigserial PRIMARY KEY,
  analisado_em timestamptz DEFAULT now(),
  queryid      bigint,
  mean_exec_ms numeric,
  calls        bigint,
  plano        text,
  modelo       text,
  analise      text
);

GRANT SELECT, INSERT ON monitor.analises_ia TO monitor_user;
GRANT USAGE ON SEQUENCE monitor.analises_ia_id_seq TO monitor_user;
