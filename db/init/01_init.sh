#!/bin/bash
set -e
# Usuário de monitoramento (somente leitura de estatísticas) usado pelo n8n
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-SQL
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  CREATE ROLE monitor_user LOGIN PASSWORD '${MONITOR_PASSWORD}';
  GRANT pg_read_all_stats TO monitor_user;
  GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO monitor_user;
SQL
