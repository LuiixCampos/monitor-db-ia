#!/bin/bash
# Monitoramento no Oracle. Em .sh (e não .sql) para usar a senha do .env.
sqlplus -s / as sysdba <<SQL
-- =====================================================================
-- Monitoramento no Oracle: usuário de leitura e view com o top SQL
-- lento do schema VAREJO (equivalente ao pg_stat_statements).
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET DEFINE OFF
ALTER SESSION SET CONTAINER = FREEPDB1;

CREATE USER monitor_user IDENTIFIED BY "${MONITOR_PASSWORD}" DEFAULT TABLESPACE users QUOTA 50M ON users;
GRANT CREATE SESSION TO monitor_user;
GRANT SELECT_CATALOG_ROLE TO monitor_user;
GRANT SELECT ANY DICTIONARY TO monitor_user;
GRANT SELECT ANY TABLE TO monitor_user;   -- só no lab, para o EXPLAIN PLAN nas tabelas do VAREJO
GRANT CREATE VIEW, CREATE TABLE TO monitor_user;

CREATE OR REPLACE VIEW monitor_user.vw_top_lentas AS
SELECT *
FROM (
  SELECT s.sql_id,
         s.plan_hash_value,
         s.executions                                              AS calls,
         ROUND(s.elapsed_time / 1000 / NULLIF(s.executions, 0), 2) AS mean_exec_ms,
         ROUND(s.elapsed_time / 1000, 2)                           AS total_exec_ms,
         s.buffer_gets,
         s.disk_reads,
         SUBSTR(s.sql_text, 1, 1000)                               AS query
  FROM v\$sql s
  WHERE s.parsing_schema_name = 'VAREJO'
    AND s.command_type = 3                 -- SELECT
    AND s.executions > 0
    AND s.sql_text NOT LIKE '%v\$sql%'
    AND s.sql_text NOT LIKE '/* SQL Analyze%'
    AND s.elapsed_time / 1000 / s.executions > 20
  ORDER BY s.elapsed_time / s.executions DESC
)
WHERE ROWNUM <= 5;

-- Plano real do cursor em memória (equivalente ao fn_explain do Postgres)
CREATE OR REPLACE FUNCTION monitor_user.fn_plano(p_sql_id VARCHAR2) RETURN CLOB AS
  v_plano CLOB;
BEGIN
  FOR r IN (SELECT plan_table_output AS linha
            FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(p_sql_id, NULL, 'TYPICAL'))) LOOP
    v_plano := v_plano || r.linha || CHR(10);
  END LOOP;
  RETURN v_plano;
END;
/

EXIT
SQL
