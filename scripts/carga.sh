#!/bin/bash
# Simula o uso de um sistema de varejo: dashboards, consultas de loja,
# estoque, transferências e inventário. Várias queries sem índice de propósito.
echo "Iniciando carga de varejo..."
AMPLIADA=$(psql -Atc "SELECT (to_regclass('fiscal.notas') IS NOT NULL)::int" 2>/dev/null || echo 0)
echo "Base ampliada: $AMPLIADA" 
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

  # ---- Base ampliada (16_base_ampliada.sql). Só roda se ela existir. ----
  if [ "$AMPLIADA" = "1" ]; then
    PROD=$(( RANDOM % 20000 + 1 ))
    NOTA=$(( (RANDOM * 32768 + RANDOM) % 2200000 + 1 ))
    VENDA=$(( (RANDOM * 32768 + RANDOM) % 1900000 + 1 ))
    CHAVE=$(printf "35%042d" $NOTA)

    # Kardex do SKU na loja (consulta do balcão)
    psql -q -c "SELECT tipo, quantidade, documento, dt_movimento FROM varejo.movimentacoes_estoque WHERE loja_id = $LOJA AND produto_id = $PROD ORDER BY dt_movimento DESC LIMIT 50;" > /dev/null

    # Notas da loja presas em contingência ou pendentes de autorização
    psql -q -c "SELECT n.numero, n.dt_emissao, n.status FROM fiscal.notas n WHERE n.loja_id = $LOJA AND n.status IN ('CONTINGENCIA', 'PENDENTE') AND n.dt_emissao >= now() - interval '2 days';" > /dev/null

    # Consulta de nota pela chave de acesso (SAC, troca)
    psql -q -c "SELECT n.numero, n.status, n.valor_total FROM fiscal.notas n WHERE n.chave_acesso = '$CHAVE';" > /dev/null

    # Itens da nota de uma venda (reimpressão de cupom)
    psql -q -c "SELECT ni.item, p.sku, ni.quantidade, ni.valor_unitario FROM fiscal.notas_itens ni JOIN fiscal.notas n ON n.id = ni.nota_id JOIN varejo.produtos p ON p.id = ni.produto_id WHERE n.venda_id = $VENDA;" > /dev/null

    # Fila de integração parada por loja (painel da central)
    psql -q -c "SELECT e.loja_id, count(*), min(e.criado_em) FROM integracao.eventos e WHERE e.status = 'PENDENTE' GROUP BY e.loja_id ORDER BY 3;" > /dev/null

    # Tempo de resposta da SEFAZ na última hora
    psql -q -c "SELECT date_trunc('minute', s.dt_evento), round(avg(s.tempo_resposta_ms)) FROM fiscal.eventos_sefaz s WHERE s.dt_evento >= now() - interval '1 hour' GROUP BY 1 ORDER BY 1;" > /dev/null

    # Pedidos de compra atrasados do CD
    psql -q -c "SELECT pc.id, f.razao_social, pc.dt_prevista FROM varejo.pedidos_compra pc JOIN varejo.fornecedores f ON f.id = pc.fornecedor_id WHERE pc.status IN ('ABERTO', 'PARCIAL') AND pc.dt_prevista < current_date AND pc.cd_id = $(( RANDOM % 3 + 1 ));" > /dev/null
  fi

  sleep 10
done
