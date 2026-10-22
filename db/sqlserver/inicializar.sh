#!/bin/bash
# Roda uma vez (serviço sqlserver-init): espera o SQL Server e cria a base do cartão.
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -x "$SQLCMD" ] || SQLCMD=/opt/mssql-tools/bin/sqlcmd
CON=(-S sqlserver-lab -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
echo "Esperando o SQL Server..."
until $SQLCMD "${CON[@]}" -Q "SELECT 1" > /dev/null 2>&1; do sleep 5; done
if [ "$($SQLCMD "${CON[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = 'cartao'")" = "1" ]; then
  echo "Base 'cartao' já existe. Nada a fazer."
  exit 0
fi
echo "Criando a base do cartão (alguns minutos)..."
$SQLCMD "${CON[@]}" -v MONITOR_PASSWORD="$MONITOR_PASSWORD" -i /sqlserver/01_cartao.sql && echo "Base do cartão criada."
