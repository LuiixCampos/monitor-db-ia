#!/bin/bash
# Carga de varejo no Oracle (equivalente ao carga.sh do Postgres)
CONN="varejo/${ORACLE_APP_PASSWORD}@oracle-lab:1521/FREEPDB1"
echo "Aguardando o Oracle..."
until echo "select 1 from dual;" | sqlplus -s -L "$CONN" >/dev/null 2>&1; do sleep 10; done
echo "Iniciando carga Oracle..."
while true; do
  LOJA=$(( RANDOM % 100 + 1 ))
  CLI=$(( (RANDOM * 32768 + RANDOM) % 100000 + 1 ))
  sqlplus -s -L "$CONN" >/dev/null <<SQL
ALTER SESSION SET CURSOR_SHARING = FORCE;
SELECT l.codigo, COUNT(*), SUM(v.valor_total) FROM vendas v JOIN lojas l ON l.id = v.loja_id WHERE v.data_hora >= SYSDATE - 1 GROUP BY l.codigo ORDER BY 3 DESC;
SELECT p.sku, SUM(i.quantidade) FROM itens_venda i JOIN vendas v ON v.id = i.venda_id JOIN produtos p ON p.id = i.produto_id WHERE v.data_hora >= SYSDATE - 30 GROUP BY p.sku ORDER BY 2 DESC FETCH FIRST 20 ROWS ONLY;
SELECT p.sku FROM estoque e JOIN produtos p ON p.id = e.produto_id WHERE e.loja_id = $LOJA AND e.qtd_disponivel = 0;
SELECT id, data_hora, valor_total FROM vendas WHERE cliente_id = $CLI ORDER BY data_hora DESC FETCH FIRST 10 ROWS ONLY;
EXIT
SQL
  sleep 10
done
