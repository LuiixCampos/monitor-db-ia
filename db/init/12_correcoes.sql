-- =====================================================================
-- Correções aplicadas pelo executor após aprovação no Jira.
-- Idempotente.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitor.correcoes (
  id          bigserial PRIMARY KEY,
  jira_key    text,
  banco       text,
  comandos    text,
  antes_ms    numeric,
  depois_ms   numeric,
  ganho_pct   numeric GENERATED ALWAYS AS (
                CASE WHEN antes_ms > 0 AND depois_ms IS NOT NULL
                     THEN round(100 * (1 - depois_ms / antes_ms), 1) END) STORED,
  resultado   text,            -- OK ou ERRO
  detalhe     text,
  aplicado_em timestamptz DEFAULT now()
);

DROP VIEW IF EXISTS bi.mon_correcoes;   -- o 15_ambientes.sql recria com mais colunas
CREATE VIEW bi.mon_correcoes AS
SELECT jira_key, banco, comandos, antes_ms, depois_ms, ganho_pct, resultado, aplicado_em, aplicado_em::date AS data
FROM monitor.correcoes;

GRANT SELECT ON monitor.correcoes, bi.mon_correcoes TO monitor_user;
