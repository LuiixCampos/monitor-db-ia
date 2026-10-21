-- =====================================================================
-- Previsão de degradação: tendência do tempo médio de cada query
-- (regressão linear sobre o histórico) e em quantos dias ela passa do
-- limite de prioridade ALTA (150 ms). Rodar depois da primeira carga.
-- =====================================================================
CREATE OR REPLACE VIEW workspace.monitor_db.vw_previsao AS
WITH serie AS (
  SELECT banco, query_id, query, coleta_em, mean_exec_ms,
         unix_timestamp(coleta_em) / 86400.0 AS dia
  FROM workspace.monitor_db.snapshots
),
tendencia AS (
  SELECT banco,
         query_id,
         any_value(query)                         AS query,
         count(*)                                 AS amostras,
         min(coleta_em)                           AS desde,
         max_by(mean_exec_ms, coleta_em)          AS atual_ms,
         regr_slope(mean_exec_ms, dia)            AS ms_por_dia,
         regr_r2(mean_exec_ms, dia)               AS r2
  FROM serie
  GROUP BY banco, query_id
  HAVING count(*) >= 10
)
SELECT banco,
       query_id,
       left(query, 120)                                       AS query,
       amostras,
       round(atual_ms, 1)                                     AS atual_ms,
       round(ms_por_dia, 2)                                   AS ms_por_dia,
       round(r2, 2)                                           AS confianca_r2,
       CASE WHEN ms_por_dia > 0 AND atual_ms < 150
            THEN ceil((150 - atual_ms) / ms_por_dia) END      AS dias_ate_alta,
       CASE WHEN atual_ms >= 150                       THEN 'JÁ ESTÁ EM ALTA'
            WHEN ms_por_dia > 0 AND (150 - atual_ms) / ms_por_dia <= 30 THEN 'ATENÇÃO: ALTA EM ATÉ 30 DIAS'
            WHEN ms_por_dia > 0                        THEN 'DEGRADANDO DEVAGAR'
            ELSE 'ESTÁVEL OU MELHORANDO' END                  AS situacao
FROM tendencia;

-- Consultas para o painel / apresentação
SELECT * FROM workspace.monitor_db.vw_previsao ORDER BY dias_ate_alta NULLS LAST, atual_ms DESC;

-- Tempo médio diário por banco (gráfico de linha)
SELECT date_trunc('DAY', coleta_em) AS dia, banco, round(avg(mean_exec_ms), 1) AS tempo_medio_ms
FROM workspace.monitor_db.snapshots
GROUP BY ALL ORDER BY dia;

-- Efetividade das correções
SELECT banco,
       count(*)                                               AS chamados,
       count(ganho_pct)                                       AS corrigidos_automaticamente,
       round(avg(ganho_pct), 1)                               AS ganho_medio_pct,
       round(avg((unix_timestamp(resolvido_em) - unix_timestamp(aberto_em)) / 3600), 1) AS horas_medias_ate_resolver
FROM workspace.monitor_db.chamados
GROUP BY banco;
