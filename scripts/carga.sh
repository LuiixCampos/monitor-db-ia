#!/bin/bash
# Roda queries ruins em loop para popular o pg_stat_statements
echo "Iniciando carga..."
while true; do
  ID=$((RANDOM % 50000 + 1))
  psql -q -c "SELECT * FROM loja.pedidos WHERE cliente_id = $ID;" > /dev/null
  psql -q -c "SELECT count(*) FROM loja.pedidos WHERE status = 'CANCELADO' AND criado_em > now() - interval '30 days';" > /dev/null
  psql -q -c "SELECT c.cidade, sum(p.valor) FROM loja.pedidos p JOIN loja.clientes c ON c.id = p.cliente_id WHERE lower(c.email) LIKE '%cliente1%' GROUP BY c.cidade;" > /dev/null
  psql -q -c "SELECT * FROM loja.pedidos ORDER BY valor DESC LIMIT 10;" > /dev/null
  sleep 5
done
