#!/bin/bash
# Simula o uso de um sistema de varejo: dashboards, consultas de loja,
# estoque, transferências e inventário. Várias queries sem índice de propósito.
echo "Iniciando carga de varejo..."
while true; do
  LOJA=$(( RANDOM % 197 + 4 ))
  CLI=$(( (RANDOM * 32768 + RANDOM) % 200000 + 1 ))
  INV=$(( RANDOM % 591 + 1 ))

  # Dashboard: vendas das últimas 24h por loja
  psql -q -c "SELECT l.codigo, l.nome, count(*), sum(v.valor_total) FROM varejo.vendas v JOIN varejo.lojas l ON l.id = v.loja_id WHERE v.data_hora >= now() - interval '1 day' GROUP BY l.codigo, l.nome ORDER BY 4 DESC;" > /dev/null

  # Top 20 SKUs mais vendidos no mês
  psql -q -c "SELECT p.sku, p.descricao, sum(i.quantidade) FROM varejo.itens_venda i JOIN varejo.vendas v ON v.id = i.venda_id JOIN varejo.produtos p ON p.id = i.produto_id WHERE v.data_hora >= now() - interval '30 days' GROUP BY p.sku, p.descricao ORDER BY 3 DESC LIMIT 20;" > /dev/null

  # Ruptura de estoque de uma loja
  psql -q -c "SELECT p.sku, p.descricao FROM varejo.estoque e JOIN varejo.produtos p ON p.id = e.produto_id WHERE e.loja_id = $LOJA AND e.qtd_disponivel = 0;" > /dev/null

  # Transferências em trânsito há mais de 7 dias para uma loja
  psql -q -c "SELECT t.id, t.produto_id, t.quantidade, t.dt_solicitacao FROM varejo.transferencias t WHERE t.status = 'EM_TRANSITO' AND t.dt_solicitacao < now() - interval '7 days' AND t.loja_destino = $LOJA;" > /dev/null

  # Histórico de compras de um cliente
  psql -q -c "SELECT v.id, v.data_hora, v.valor_total FROM varejo.vendas v WHERE v.cliente_id = $CLI ORDER BY v.data_hora DESC LIMIT 10;" > /dev/null

  # Divergências de um inventário
  psql -q -c "SELECT p.sku, ii.qtd_sistema, ii.qtd_contada FROM varejo.inventario_itens ii JOIN varejo.produtos p ON p.id = ii.produto_id WHERE ii.inventario_id = $INV AND ii.qtd_contada <> ii.qtd_sistema;" > /dev/null

  sleep 10
done
