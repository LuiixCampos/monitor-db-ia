#!/bin/bash
# Simula o sistema do cartão no SQL Server: extrato no app, fatura,
# autorização na loja, negativas por loja, régua de cobrança e conciliação.
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -x "$SQLCMD" ] || SQLCMD=/opt/mssql-tools/bin/sqlcmd
q() { $SQLCMD -S sqlserver-lab -U sa -P "$MSSQL_SA_PASSWORD" -C -d cartao -Q "SET NOCOUNT ON; $1" > /dev/null 2>&1; }
echo "Iniciando carga do cartão (SQL Server)..."
until $SQLCMD -S sqlserver-lab -U sa -P "$MSSQL_SA_PASSWORD" -C -d cartao -Q "SELECT TOP 1 1 FROM fin.cobranca_eventos" > /dev/null 2>&1; do sleep 15; done
while true; do
  CONTA=$(( (RANDOM * 32768 + RANDOM) % 120000 + 1 ))
  CARTAO=$(( (RANDOM * 32768 + RANDOM) % 180000 + 1 ))
  LOJA=$(( RANDOM % 197 + 4 ))

  # Extrato do cartão no app
  q "SELECT TOP 50 t.dt_transacao, t.valor, t.parcelas, t.status FROM fin.transacoes t WHERE t.conta_id = $CONTA ORDER BY t.dt_transacao DESC"
  # Fatura em aberto
  q "SELECT f.competencia, f.valor_total, f.valor_minimo, f.dt_vencimento FROM fin.faturas f WHERE f.conta_id = $CONTA AND f.status IN ('ABERTA', 'ATRASADA')"
  # Autorização na loja: gasto do cartão nas últimas 24h (antifraude)
  q "SELECT COUNT(*), SUM(t.valor) FROM fin.transacoes t WHERE t.cartao_id = $CARTAO AND t.status = 'APROVADA' AND t.dt_transacao >= DATEADD(hour, -24, SYSDATETIME())"
  # Negativas da loja no último dia
  q "SELECT t.motivo_negativa, COUNT(*) FROM fin.transacoes t WHERE t.loja_id = $LOJA AND t.status = 'NEGADA' AND t.dt_transacao >= DATEADD(day, -1, SYSDATETIME()) GROUP BY t.motivo_negativa"
  # Régua de cobrança: carteira em atraso por faixa
  q "SELECT CASE WHEN DATEDIFF(day, f.dt_vencimento, GETDATE()) <= 30 THEN '0-30' WHEN DATEDIFF(day, f.dt_vencimento, GETDATE()) <= 90 THEN '31-90' ELSE '90+' END, COUNT(*), SUM(f.valor_total - f.valor_pago) FROM fin.faturas f WHERE f.status = 'ATRASADA' GROUP BY CASE WHEN DATEDIFF(day, f.dt_vencimento, GETDATE()) <= 30 THEN '0-30' WHEN DATEDIFF(day, f.dt_vencimento, GETDATE()) <= 90 THEN '31-90' ELSE '90+' END"
  # Conciliação dos pagamentos de hoje por canal
  q "SELECT p.canal, COUNT(*), SUM(p.valor) FROM fin.pagamentos p WHERE p.dt_pagamento >= CAST(GETDATE() AS date) GROUP BY p.canal"
  sleep 10
done
