-- =====================================================================
-- Ambientes DEV / HML / PRD.
-- PRD é onde as queries lentas são coletadas. A correção aprovada é
-- testada e medida primeiro em HML (mesma base e mesma carga de PRD) e só
-- vai para PRD se o ganho em HML for real e a mudança for aprovada.
-- Senhas não ficam aqui: o executor usa as do .env.
-- Idempotente.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitor.ambientes (
  ambiente          text,     -- DEV, HML, PRD
  banco             text,     -- POSTGRES, ORACLE
  host              text,
  porta             int,
  nome_banco        text,
  papel             text,
  coletar           boolean DEFAULT false,  -- monitor lê as queries lentas daqui
  testar_correcoes  boolean DEFAULT false,  -- correção aprovada é testada aqui antes
  aplicar_correcoes boolean DEFAULT false,  -- correção liberada é aplicada aqui
  ativo             boolean DEFAULT true,
  PRIMARY KEY (ambiente, banco)
);

INSERT INTO monitor.ambientes (ambiente, banco, host, porta, nome_banco, papel, coletar, testar_correcoes, aplicar_correcoes) VALUES
  ('PRD', 'POSTGRES', 'postgres-lab', 5432, 'lab',      'Produção: coleta das queries lentas. Recebe a correção só depois do teste em HML e da aprovação da mudança.', true,  false, true),
  ('HML', 'POSTGRES', 'postgres-hml', 5432, 'lab',      'Homologação: mesma base e mesma carga de PRD. A correção é aplicada e medida aqui primeiro.',               false, true,  false),
  ('DEV', 'POSTGRES', 'postgres-dev', 5432, 'lab',      'Desenvolvimento: sem coleta e sem correção automática.',                                                   false, false, false),
  ('PRD', 'ORACLE',   'oracle-lab',   1521, 'FREEPDB1', 'Produção Oracle. Sem HML no lab: aplica direto após aprovação.',                                          true,  false, true)
ON CONFLICT DO NOTHING;

ALTER TABLE monitor.analises_ia ADD COLUMN IF NOT EXISTS ambiente text DEFAULT 'PRD';
ALTER TABLE monitor.correcoes   ADD COLUMN IF NOT EXISTS ambiente text DEFAULT 'PRD';
ALTER TABLE monitor.correcoes   ADD COLUMN IF NOT EXISTS liberado boolean;   -- teste em HML liberou para PRD?
ALTER TABLE monitor.correcoes   ADD COLUMN IF NOT EXISTS paridade text;      -- diferenças HML x PRD encontradas no teste

-- Chamado passa a mostrar o ambiente de origem
CREATE OR REPLACE FUNCTION monitor.fn_abrir_chamados()
RETURNS TABLE (numero text, prioridade text, titulo text, mean_exec_ms numeric, calls bigint, query text, analise text)
LANGUAGE sql AS $fn$
  WITH novos AS (
    INSERT INTO monitor.chamados (analise_id, titulo, prioridade)
    SELECT a.id,
           coalesce(a.ambiente, 'PRD') || ' | ' || initcap(coalesce(a.banco, 'POSTGRES'))
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

-- Esteira de cada chamado: teste em HML -> aplicação em PRD
CREATE OR REPLACE VIEW monitor.vw_esteira AS
SELECT c.numero, c.jira_key, coalesce(a.banco, 'POSTGRES') AS banco, a.mean_exec_ms AS prd_detectado_ms,
       h.antes_ms AS hml_antes_ms, h.depois_ms AS hml_depois_ms, h.ganho_pct AS hml_ganho_pct, h.aplicado_em AS hml_testado_em, h.paridade,
       p.antes_ms AS prd_antes_ms, p.depois_ms AS prd_depois_ms, p.ganho_pct AS prd_ganho_pct, p.aplicado_em AS prd_aplicado_em,
       CASE WHEN p.id IS NOT NULL          THEN 'APLICADO_PRD'
            WHEN h.liberado                THEN 'LIBERADO_PRD'
            WHEN h.id IS NOT NULL          THEN 'REPROVADO_HML'
            ELSE 'AGUARDANDO_TESTE' END AS etapa
FROM monitor.chamados c
LEFT JOIN monitor.analises_ia a ON a.id = c.analise_id
LEFT JOIN LATERAL (SELECT * FROM monitor.correcoes x WHERE x.jira_key = c.jira_key AND x.ambiente = 'HML' AND x.resultado = 'OK'
                   ORDER BY x.aplicado_em DESC LIMIT 1) h ON true
LEFT JOIN LATERAL (SELECT * FROM monitor.correcoes x WHERE x.jira_key = c.jira_key AND x.ambiente = 'PRD' AND x.resultado = 'OK'
                   ORDER BY x.aplicado_em DESC LIMIT 1) p ON true
WHERE c.jira_key IS NOT NULL;

-- BI: correções por ambiente e a esteira
CREATE OR REPLACE VIEW bi.mon_correcoes AS
SELECT jira_key, banco, comandos, antes_ms, depois_ms, ganho_pct, resultado, aplicado_em, aplicado_em::date AS data,
       coalesce(ambiente, 'PRD') AS ambiente, liberado, paridade
FROM monitor.correcoes;

CREATE OR REPLACE VIEW bi.mon_esteira AS SELECT * FROM monitor.vw_esteira;

CREATE OR REPLACE VIEW bi.mon_ambientes AS
SELECT ambiente, banco, papel, coletar, testar_correcoes, aplicar_correcoes, ativo FROM monitor.ambientes;

GRANT SELECT ON monitor.ambientes, monitor.vw_esteira, bi.mon_correcoes, bi.mon_esteira, bi.mon_ambientes TO monitor_user;
