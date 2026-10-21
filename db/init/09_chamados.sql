-- =====================================================================
-- Chamados (ChatOps): cada diagnóstico da IA vira um chamado DB-0001,
-- postado no Slack pelo n8n e atualizado por formulário.
-- Idempotente: pode ser rodado num banco já existente.
-- =====================================================================
CREATE SEQUENCE IF NOT EXISTS monitor.chamados_seq;

CREATE TABLE IF NOT EXISTS monitor.chamados (
  id            bigint PRIMARY KEY DEFAULT nextval('monitor.chamados_seq'),
  numero        text GENERATED ALWAYS AS ('DB-' || lpad(id::text, 4, '0')) STORED,
  analise_id    bigint UNIQUE REFERENCES monitor.analises_ia (id) ON DELETE SET NULL,
  titulo        text,
  prioridade    text,           -- ALTA (>= 150 ms), MEDIA (>= 50 ms), BAIXA
  status        text DEFAULT 'ABERTO',
  responsavel   text,
  comentario    text,
  aberto_em     timestamptz DEFAULT now(),
  atualizado_em timestamptz DEFAULT now(),
  resolvido_em  timestamptz
);

-- Abre chamado para toda análise que ainda não tem um. Retorna os abertos agora.
CREATE OR REPLACE FUNCTION monitor.fn_abrir_chamados()
RETURNS TABLE (numero text, prioridade text, titulo text, mean_exec_ms numeric, calls bigint, query text, analise text)
LANGUAGE sql AS $fn$
  WITH novos AS (
    INSERT INTO monitor.chamados (analise_id, titulo, prioridade)
    SELECT a.id,
           'Query lenta: ' || round(a.mean_exec_ms) || ' ms em média',
           CASE WHEN a.mean_exec_ms >= 150 THEN 'ALTA'
                WHEN a.mean_exec_ms >= 50  THEN 'MEDIA'
                ELSE 'BAIXA' END
    FROM monitor.analises_ia a
    WHERE a.analise IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM monitor.chamados c WHERE c.analise_id = a.id)
    RETURNING *
  )
  SELECT n.numero, n.prioridade, n.titulo, a.mean_exec_ms, a.calls,
         left(coalesce((SELECT s.query FROM pg_stat_statements s
                        WHERE s.queryid = a.queryid ORDER BY s.toplevel DESC LIMIT 1), '?'), 400),
         left(a.analise, 2500)
  FROM novos n
  JOIN monitor.analises_ia a ON a.id = n.analise_id
  ORDER BY a.mean_exec_ms DESC;
$fn$;

-- Atualiza o chamado pelo número (DB-0001 ou só 1)
CREATE OR REPLACE FUNCTION monitor.fn_atualizar_chamado(p_numero text, p_status text, p_responsavel text, p_comentario text)
RETURNS TABLE (numero text, titulo text, status text, responsavel text, comentario text, minutos_aberto numeric)
LANGUAGE sql AS $fn$
  UPDATE monitor.chamados c
  SET status        = upper(p_status),
      responsavel   = coalesce(nullif(p_responsavel, ''), c.responsavel),
      comentario    = coalesce(nullif(p_comentario, ''), c.comentario),
      atualizado_em = now(),
      resolvido_em  = CASE WHEN upper(p_status) = 'RESOLVIDO' THEN now() ELSE NULL END
  WHERE c.id = regexp_replace(p_numero, '\D', '', 'g')::bigint
  RETURNING c.numero, c.titulo, c.status, c.responsavel, c.comentario,
            round(extract(epoch FROM now() - c.aberto_em) / 60, 1);
$fn$;

-- Para o BI
CREATE OR REPLACE VIEW bi.mon_chamados AS
SELECT numero, titulo, prioridade, status, responsavel, aberto_em, aberto_em::date AS data, resolvido_em,
       round(extract(epoch FROM coalesce(resolvido_em, now()) - aberto_em) / 3600, 1) AS horas_aberto
FROM monitor.chamados;

GRANT SELECT, INSERT, UPDATE ON monitor.chamados TO monitor_user;
GRANT USAGE ON SEQUENCE monitor.chamados_seq TO monitor_user;
GRANT SELECT ON bi.mon_chamados TO monitor_user;
