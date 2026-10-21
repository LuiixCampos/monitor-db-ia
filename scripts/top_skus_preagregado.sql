-- =====================================================================
-- Correção do "Top 20 SKUs do mês": o gargalo não era índice, e sim somar
-- ~160 mil itens de venda a cada execução. Solução de modelagem: deixar o
-- ranking dos últimos 30 dias pré-calculado (materialized view) e
-- atualizar de hora em hora pelo n8n. Troca: o dado pode ter até 1h de atraso,
-- o que é aceitável para um painel de ranking.
-- Uso: docker exec postgres-lab psql -U labadmin -d lab -f /scripts/top_skus_preagregado.sql
-- =====================================================================
\echo 'Criando a materialized view de vendas por SKU (ultimos 30 dias)...'
CREATE MATERIALIZED VIEW IF NOT EXISTS varejo.mv_skus_ultimos_30d AS
SELECT i.produto_id,
       sum(i.quantidade)                                 AS quantidade,
       sum(i.quantidade * i.preco_unitario - i.desconto) AS valor,
       now()                                             AS atualizado_em
FROM varejo.itens_venda i
JOIN varejo.vendas v ON v.id = i.venda_id
WHERE v.data_hora >= now() - interval '30 days'
GROUP BY i.produto_id;

-- Índice único: permite REFRESH ... CONCURRENTLY (sem bloquear leituras)
CREATE UNIQUE INDEX IF NOT EXISTS mv_skus_ultimos_30d_uk  ON varejo.mv_skus_ultimos_30d (produto_id);
CREATE INDEX        IF NOT EXISTS mv_skus_ultimos_30d_qtd ON varejo.mv_skus_ultimos_30d (quantidade DESC);
ANALYZE varejo.mv_skus_ultimos_30d;

GRANT SELECT ON varejo.mv_skus_ultimos_30d TO monitor_user;

\echo 'Tamanho da tabela pre-agregada:'
SELECT count(*) AS linhas, pg_size_pretty(pg_total_relation_size('varejo.mv_skus_ultimos_30d')) AS tamanho
FROM varejo.mv_skus_ultimos_30d;

-- Atualização periódica (o n8n chama de hora em hora). SECURITY DEFINER porque
-- só o dono da view pode dar REFRESH; o monitor_user só ganha o direito de chamar.
CREATE OR REPLACE FUNCTION monitor.fn_refresh_preagregados() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $fn$
DECLARE
  t0 timestamptz := clock_timestamp();
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY varejo.mv_skus_ultimos_30d;
  RETURN 'mv_skus_ultimos_30d atualizada em ' || round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1) || ' s';
END
$fn$;
REVOKE ALL ON FUNCTION monitor.fn_refresh_preagregados() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION monitor.fn_refresh_preagregados() TO monitor_user;

\echo 'Medindo a consulta nova (fase depois)...'
SELECT monitor.fn_medir('depois', 'Top 20 SKUs do mes',
  $q$SELECT p.sku, p.descricao, m.quantidade FROM varejo.mv_skus_ultimos_30d m JOIN varejo.produtos p ON p.id = m.produto_id ORDER BY m.quantidade DESC LIMIT 20$q$);

SELECT consulta, antes_ms, depois_ms, ganho_pct, plano_depois
FROM monitor.vw_benchmark_comparativo
WHERE consulta = 'Top 20 SKUs do mes';
