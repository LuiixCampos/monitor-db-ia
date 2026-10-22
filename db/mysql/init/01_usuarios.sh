#!/bin/bash
# Usuário de monitoramento: lê o performance_schema e faz EXPLAIN (SELECT nas tabelas).
mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-SQL
  CREATE USER IF NOT EXISTS 'monitor_user'@'%' IDENTIFIED BY '${MONITOR_PASSWORD}';
  GRANT PROCESS ON *.* TO 'monitor_user'@'%';
  GRANT SELECT ON performance_schema.* TO 'monitor_user'@'%';
  GRANT SELECT, EXECUTE ON sys.* TO 'monitor_user'@'%';
  GRANT SELECT, SHOW VIEW ON ecommerce.* TO 'monitor_user'@'%';
SQL
