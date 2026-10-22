#!/bin/bash
# Simula o uso do e-commerce/app no MySQL: área do cliente, rastreio,
# retira em loja, conciliação de pagamentos e carrinhos abandonados.
echo "Iniciando carga do e-commerce (MySQL)..."
until mysql -e "SELECT 1 FROM ecommerce.log_integracao_erp LIMIT 1" > /dev/null 2>&1; do sleep 10; done
while true; do
  CLI=$(( (RANDOM * 32768 + RANDOM) % 300000 + 1 ))
  PED=$(( (RANDOM * 32768 + RANDOM) % 590000 + 1 ))
  LOJA=$(( RANDOM % 197 + 4 ))

  # Meus pedidos (área do cliente no app)
  mysql -e "SELECT id, dt_pedido, status, valor_total FROM ecommerce.pedidos WHERE cliente_id = $CLI ORDER BY dt_pedido DESC LIMIT 10" > /dev/null
  # Rastreio do pedido
  mysql -e "SELECT evento, transportadora, dt_evento FROM ecommerce.rastreio_eventos WHERE pedido_id = $PED ORDER BY dt_evento" > /dev/null
  # Itens do pedido com o título do produto
  mysql -e "SELECT i.sku, s.titulo, i.quantidade, i.preco FROM ecommerce.pedido_itens i JOIN ecommerce.produtos_site s ON s.sku = i.sku WHERE i.pedido_id = $PED" > /dev/null
  # Pedidos de retira em loja parados há mais de 3 dias
  mysql -e "SELECT p.id, p.dt_pedido, p.valor_total FROM ecommerce.pedidos p WHERE p.modalidade = 'RETIRA_LOJA' AND p.status = 'AGUARDANDO_RETIRADA' AND p.loja_atendimento = $LOJA AND p.dt_pedido < NOW() - INTERVAL 3 DAY" > /dev/null
  # Conciliação: pagamentos pendentes há mais de 30 minutos
  mysql -e "SELECT g.id, g.pedido_id, g.meio, g.valor FROM ecommerce.pagamentos g WHERE g.status = 'PENDENTE' AND g.dt_criacao < NOW() - INTERVAL 30 MINUTE" > /dev/null
  # Carrinhos abandonados para campanha de remarketing
  mysql -e "SELECT c.id, c.cliente_id, c.atualizado_em FROM ecommerce.carrinhos c WHERE c.status = 'ABERTO' AND c.cliente_id = $CLI" > /dev/null
  sleep 10
done
