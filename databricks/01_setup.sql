-- =====================================================================
-- monitor-db-ia no Databricks (Free Edition)
-- Rodar uma vez no SQL Editor, com o Serverless Starter Warehouse.
-- O n8n preenche estas tabelas a cada hora (INSERT OVERWRITE).
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS workspace.monitor_db
COMMENT 'Histórico de performance e chamados do lab monitor-db-ia';

CREATE TABLE IF NOT EXISTS workspace.monitor_db.snapshots (
  coleta_em     TIMESTAMP,
  banco         STRING,
  query_id      STRING,
  query         STRING,
  calls         BIGINT,
  mean_exec_ms  DOUBLE,
  origem        STRING  COMMENT 'REAL = coletado; SIMULADO = histórico gerado para demonstrar a previsão'
);

CREATE TABLE IF NOT EXISTS workspace.monitor_db.chamados (
  numero        STRING,
  jira_key      STRING,
  banco         STRING,
  prioridade    STRING,
  status        STRING,
  mean_exec_ms  DOUBLE,
  aberto_em     TIMESTAMP,
  resolvido_em  TIMESTAMP,
  antes_ms      DOUBLE,
  depois_ms     DOUBLE,
  ganho_pct     DOUBLE
);
