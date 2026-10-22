#!/bin/bash
# =====================================================================
# TimescaleDB: histórico de performance de longo prazo (alternativa ao
# Databricks que roda dentro do lab).
#  - monitor.snapshots vira hypertable (partição por tempo)
#  - compressão depois de 14 dias e retenção de 400 dias
#  - agregado contínuo diário e previsão por regressão linear
#  - um job do próprio Timescale copia os snapshots do monitor a cada 15 min
# =====================================================================
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-SQL
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Origem: o schema monitor do postgres-lab (somente leitura)
CREATE SERVER lab FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'postgres-lab', port '5432', dbname '${LAB_DB}');
CREATE USER MAPPING FOR PUBLIC SERVER lab
  OPTIONS (user 'monitor_user', password '${MONITOR_PASSWORD}');
CREATE SCHEMA origem;
IMPORT FOREIGN SCHEMA monitor LIMIT TO (snapshots) FROM SERVER lab INTO origem;

CREATE SCHEMA monitor;
CREATE TABLE monitor.snapshots (
  coleta_em     timestamptz NOT NULL,
  banco         text,
  query_id      text,
  query         text,
  calls         bigint,
  mean_exec_ms  numeric,
  total_exec_ms numeric,
  origem        text,
  PRIMARY KEY (coleta_em, banco, query_id)
);
SELECT create_hypertable('monitor.snapshots', 'coleta_em', chunk_time_interval => INTERVAL '7 days');
ALTER TABLE monitor.snapshots SET (timescaledb.compress,
  timescaledb.compress_segmentby = 'banco, query_id', timescaledb.compress_orderby = 'coleta_em');
SELECT add_compression_policy('monitor.snapshots', INTERVAL '14 days');
SELECT add_retention_policy('monitor.snapshots', INTERVAL '400 days');

-- Agregado contínuo: uma linha por query por dia, atualizado de hora em hora
CREATE MATERIALIZED VIEW monitor.snapshots_diario WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 day', coleta_em) AS dia, banco, query_id,
       avg(mean_exec_ms) AS media_ms, max(mean_exec_ms) AS pior_ms,
       last(query, coleta_em) AS query, count(*) AS amostras
FROM monitor.snapshots
GROUP BY 1, 2, 3
WITH NO DATA;
SELECT add_continuous_aggregate_policy('monitor.snapshots_diario',
  start_offset => INTERVAL '400 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');

-- Previsão sobre a série diária (mesma regra do monitor: limite de 150 ms)
CREATE VIEW monitor.vw_previsao AS
WITH t AS (
  SELECT banco, query_id, (array_agg(query ORDER BY dia DESC))[1] AS query, count(*) AS dias,
         (array_agg(media_ms ORDER BY dia DESC))[1] AS atual_ms,
         regr_slope(media_ms, extract(epoch FROM dia) / 86400.0) AS ms_por_dia,
         regr_r2(media_ms, extract(epoch FROM dia) / 86400.0) AS r2
  FROM monitor.snapshots_diario
  GROUP BY banco, query_id
  HAVING count(*) >= 7
)
SELECT banco, query_id, left(query, 120) AS query, dias, round(atual_ms, 1) AS atual_ms,
       round(ms_por_dia::numeric, 2) AS ms_por_dia, round(r2::numeric, 2) AS confianca_r2,
       CASE WHEN ms_por_dia > 0 AND atual_ms < 150 THEN ceil((150 - atual_ms) / ms_por_dia::numeric) END AS dias_ate_alta
FROM t;

-- Cópia incremental: traz o que é novo (e o histórico simulado na primeira vez)
CREATE PROCEDURE monitor.sincronizar(job_id int DEFAULT NULL, config jsonb DEFAULT NULL)
LANGUAGE plpgsql AS \$\$
DECLARE
  desde timestamptz := coalesce((SELECT max(coleta_em) FROM monitor.snapshots WHERE origem = 'REAL'), '-infinity');
  n bigint;
BEGIN
  INSERT INTO monitor.snapshots
  SELECT o.coleta_em, o.banco, o.query_id, o.query, o.calls, o.mean_exec_ms, o.total_exec_ms, o.origem
  FROM origem.snapshots o
  WHERE o.coleta_em > desde - INTERVAL '1 hour'
     OR (o.origem = 'SIMULADO' AND NOT EXISTS (SELECT 1 FROM monitor.snapshots s WHERE s.origem = 'SIMULADO'))
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'snapshots copiados: %', n;
END
\$\$;
SELECT add_job('monitor.sincronizar', INTERVAL '15 minutes');

-- Leitura para o Grafana
CREATE ROLE grafana_ts LOGIN PASSWORD '${MONITOR_PASSWORD}';
GRANT USAGE ON SCHEMA monitor TO grafana_ts;
GRANT SELECT ON ALL TABLES IN SCHEMA monitor TO grafana_ts;
SQL
