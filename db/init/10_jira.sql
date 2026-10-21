-- Vínculo dos chamados com o Jira Service Management. Idempotente.
ALTER TABLE monitor.chamados ADD COLUMN IF NOT EXISTS jira_key text;
ALTER TABLE monitor.chamados ADD COLUMN IF NOT EXISTS jira_url text;

-- Grava a chave do Jira no chamado recém-aberto
CREATE OR REPLACE FUNCTION monitor.fn_vincular_jira(p_numero text, p_key text, p_url text)
RETURNS TABLE (numero text, jira_key text, jira_url text, prioridade text, titulo text)
LANGUAGE sql AS $fn$
  UPDATE monitor.chamados c
  SET jira_key = p_key, jira_url = p_url, atualizado_em = now()
  WHERE c.numero = p_numero
  RETURNING c.numero, c.jira_key, c.jira_url, c.prioridade, c.titulo;
$fn$;

-- Traz o status do Jira de volta (categoria: new / indeterminate / done)
CREATE OR REPLACE FUNCTION monitor.fn_sincronizar_jira(p_key text, p_categoria text, p_responsavel text)
RETURNS TABLE (numero text, status text)
LANGUAGE sql AS $fn$
  UPDATE monitor.chamados c
  SET status        = CASE p_categoria WHEN 'done' THEN 'RESOLVIDO'
                                       WHEN 'indeterminate' THEN 'EM_ANDAMENTO'
                                       ELSE 'ABERTO' END,
      responsavel   = coalesce(nullif(p_responsavel, ''), c.responsavel),
      resolvido_em  = CASE WHEN p_categoria = 'done' THEN coalesce(c.resolvido_em, now()) END,
      atualizado_em = now()
  WHERE c.jira_key = p_key
  RETURNING c.numero, c.status;
$fn$;

CREATE OR REPLACE VIEW bi.mon_chamados AS
SELECT numero, jira_key, jira_url, titulo, prioridade, status, responsavel, aberto_em, aberto_em::date AS data, resolvido_em,
       round(extract(epoch FROM coalesce(resolvido_em, now()) - aberto_em) / 3600, 1) AS horas_aberto
FROM monitor.chamados;
GRANT SELECT ON bi.mon_chamados TO monitor_user;
