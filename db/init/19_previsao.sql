-- =====================================================================
-- Previsão de degradação dentro do próprio monitor (sem Databricks).
-- Mesma lógica do databricks/02_previsao.sql: regressão linear do tempo
-- médio de cada query sobre o histórico (monitor.snapshots) e em quantos
-- dias ela passa do limite de prioridade ALTA (150 ms).
-- O Grafana e o Power BI leem daqui. Idempotente.
-- =====================================================================
CREATE OR REPLACE VIEW monitor.vw_previsao AS
WITH tendencia AS (
  SELECT banco, query_id,
         (array_agg(query ORDER BY coleta_em DESC))[1]        AS query,
         count(*)                                             AS amostras,
         min(coleta_em)                                       AS desde,
         (array_agg(mean_exec_ms ORDER BY coleta_em DESC))[1] AS atual_ms,
         regr_slope(mean_exec_ms, extract(epoch FROM coleta_em) / 86400.0) AS ms_por_dia,
         regr_r2(mean_exec_ms, extract(epoch FROM coleta_em) / 86400.0)    AS r2,
         bool_or(origem = 'SIMULADO')                         AS tem_simulado
  FROM monitor.snapshots
  GROUP BY banco, query_id
  HAVING count(*) >= 10
)
SELECT banco, query_id, left(query, 120) AS query, amostras,
       round(atual_ms, 1)                    AS atual_ms,
       round(ms_por_dia::numeric, 2)         AS ms_por_dia,
       round(r2::numeric, 2)                 AS confianca_r2,
       CASE WHEN ms_por_dia > 0 AND atual_ms < 150 THEN ceil((150 - atual_ms) / ms_por_dia::numeric) END AS dias_ate_alta,
       CASE WHEN atual_ms >= 150 THEN 'JÁ ESTÁ EM ALTA'
            WHEN ms_por_dia > 0 AND (150 - atual_ms) / ms_por_dia::numeric <= 30 THEN 'ATENÇÃO: ALTA EM ATÉ 30 DIAS'
            WHEN ms_por_dia > 0 THEN 'DEGRADANDO DEVAGAR'
            ELSE 'ESTÁVEL OU MELHORANDO' END AS situacao,
       tem_simulado
FROM tendencia;

-- Tempo médio diário por banco (gráfico de linha)
CREATE OR REPLACE VIEW monitor.vw_tempo_diario AS
SELECT date_trunc('day', coleta_em) AS dia, banco, round(avg(mean_exec_ms), 1) AS tempo_medio_ms
FROM monitor.snapshots
GROUP BY 1, 2;

-- Efetividade das correções por banco
CREATE OR REPLACE VIEW monitor.vw_efetividade AS
SELECT monitor.fn_nome_banco(coalesce(a.banco, 'POSTGRES')) AS banco,
       count(*)                                              AS chamados,
       count(k.ganho_pct)                                    AS corrigidos_automaticamente,
       round(avg(k.ganho_pct), 1)                            AS ganho_medio_pct,
       round(avg(extract(epoch FROM c.resolvido_em - c.aberto_em) / 3600)::numeric, 1) AS horas_medias_ate_resolver
FROM monitor.chamados c
LEFT JOIN monitor.analises_ia a ON a.id = c.analise_id
LEFT JOIN LATERAL (SELECT ganho_pct FROM monitor.correcoes x
                   WHERE x.jira_key = c.jira_key AND x.resultado = 'OK' AND coalesce(x.ambiente, 'PRD') = 'PRD'
                   ORDER BY x.aplicado_em DESC LIMIT 1) k ON true
GROUP BY 1;

CREATE OR REPLACE VIEW bi.mon_previsao   AS SELECT * FROM monitor.vw_previsao;
CREATE OR REPLACE VIEW bi.mon_efetividade AS SELECT * FROM monitor.vw_efetividade;

GRANT SELECT ON monitor.vw_previsao, monitor.vw_tempo_diario, monitor.vw_efetividade,
                bi.mon_previsao, bi.mon_efetividade TO monitor_user;
