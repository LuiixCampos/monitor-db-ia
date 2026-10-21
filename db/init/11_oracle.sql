-- =====================================================================
-- Oracle no monitor: o coletor (scripts/coletor_oracle.py) grava aqui as
-- queries lentas do V$SQL, com o plano (DBMS_XPLAN) e as pistas.
-- O analisador do n8n e os chamados no Jira passam a cobrir os dois bancos.
-- Idempotente.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitor.oracle_lentas (
  sql_id        text PRIMARY KEY,
  query         text,
  calls         bigint,
  mean_exec_ms  numeric,
  plano         text,
  pistas        text,
  atualizado_em timestamptz DEFAULT now()
);

ALTER TABLE monitor.analises_ia ADD COLUMN IF NOT EXISTS banco text DEFAULT 'POSTGRES';
ALTER TABLE monitor.analises_ia ADD COLUMN IF NOT EXISTS sql_id text;
ALTER TABLE monitor.analises_ia ADD COLUMN IF NOT EXISTS query_texto text;

-- Fila do analisador Oracle: lentas ainda sem análise nas últimas 24h
CREATE OR REPLACE VIEW monitor.vw_oracle_pendentes AS
SELECT o.*
FROM monitor.oracle_lentas o
WHERE o.atualizado_em > now() - interval '1 hour'
  AND NOT EXISTS (
    SELECT 1 FROM monitor.analises_ia a
    WHERE a.sql_id = o.sql_id
      AND a.analisado_em > now() - interval '24 hours')
ORDER BY o.mean_exec_ms DESC
LIMIT 5;

-- Chamados passam a indicar o banco e usam o texto gravado na análise
CREATE OR REPLACE FUNCTION monitor.fn_abrir_chamados()
RETURNS TABLE (numero text, prioridade text, titulo text, mean_exec_ms numeric, calls bigint, query text, analise text)
LANGUAGE sql AS $fn$
  WITH novos AS (
    INSERT INTO monitor.chamados (analise_id, titulo, prioridade)
    SELECT a.id,
           initcap(coalesce(a.banco, 'POSTGRES')) || ' - query lenta: ' || round(a.mean_exec_ms) || ' ms em média',
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

GRANT SELECT, INSERT, UPDATE ON monitor.oracle_lentas TO monitor_user;
GRANT SELECT ON monitor.vw_oracle_pendentes TO monitor_user;
