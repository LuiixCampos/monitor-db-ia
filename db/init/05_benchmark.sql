-- =====================================================================
-- Benchmark antes/depois: mede o tempo REAL (EXPLAIN ANALYZE) das
-- consultas do sistema de varejo, com parâmetros fixos, e guarda o
-- histórico para comparar e alimentar o BI.
-- Idempotente: pode ser rodado de novo num banco já existente.
-- =====================================================================

CREATE TABLE IF NOT EXISTS monitor.benchmark (
  id           bigserial PRIMARY KEY,
  executado_em timestamptz DEFAULT now(),
  fase         text,          -- 'antes', 'depois' ou outro rótulo
  consulta     text,
  repeticoes   int,
  media_ms     numeric,
  min_ms       numeric,
  max_ms       numeric,
  usa_indice   boolean,
  acessos      text           -- como cada tabela foi lida (Seq Scan, Index Scan...)
);

CREATE OR REPLACE FUNCTION monitor.fn_benchmark(p_fase text, p_repeticoes int DEFAULT 5) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
  q      record;
  i      int;
  v_txt  text;
  v_plan jsonb;
  v_ms   numeric;
  v_tot  numeric;
  v_min  numeric;
  v_max  numeric;
BEGIN
  FOR q IN
    SELECT * FROM (VALUES
      ('Vendas 24h por loja',
       $q$SELECT l.codigo, l.nome, count(*), sum(v.valor_total) FROM varejo.vendas v JOIN varejo.lojas l ON l.id = v.loja_id WHERE v.data_hora >= now() - interval '1 day' GROUP BY l.codigo, l.nome ORDER BY 4 DESC$q$),
      ('Top 20 SKUs do mes',
       $q$SELECT p.sku, p.descricao, sum(i.quantidade) FROM varejo.itens_venda i JOIN varejo.vendas v ON v.id = i.venda_id JOIN varejo.produtos p ON p.id = i.produto_id WHERE v.data_hora >= now() - interval '30 days' GROUP BY p.sku, p.descricao ORDER BY 3 DESC LIMIT 20$q$),
      ('Ruptura de estoque da loja',
       $q$SELECT p.sku, p.descricao FROM varejo.estoque e JOIN varejo.produtos p ON p.id = e.produto_id WHERE e.loja_id = 50 AND e.qtd_disponivel = 0$q$),
      ('Transferencias atrasadas',
       $q$SELECT t.id, t.produto_id, t.quantidade, t.dt_solicitacao FROM varejo.transferencias t WHERE t.status = 'EM_TRANSITO' AND t.dt_solicitacao < now() - interval '7 days' AND t.loja_destino = 50$q$),
      ('Historico do cliente',
       $q$SELECT v.id, v.data_hora, v.valor_total FROM varejo.vendas v WHERE v.cliente_id = 12345 ORDER BY v.data_hora DESC LIMIT 10$q$),
      ('Divergencia de inventario',
       $q$SELECT p.sku, ii.qtd_sistema, ii.qtd_contada FROM varejo.inventario_itens ii JOIN varejo.produtos p ON p.id = ii.produto_id WHERE ii.inventario_id = 100 AND ii.qtd_contada <> ii.qtd_sistema$q$)
    ) t(nome, sql)
  LOOP
    EXECUTE 'EXPLAIN (ANALYZE) ' || q.sql;   -- aquecimento (cache), não conta
    v_tot := 0; v_min := NULL; v_max := NULL;
    FOR i IN 1..p_repeticoes LOOP
      EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q.sql INTO v_txt;
      v_plan := v_txt::jsonb;
      v_ms   := (v_plan->0->>'Execution Time')::numeric;
      v_tot  := v_tot + v_ms;
      v_min  := least(coalesce(v_min, v_ms), v_ms);
      v_max  := greatest(coalesce(v_max, v_ms), v_ms);
    END LOOP;

    INSERT INTO monitor.benchmark (fase, consulta, repeticoes, media_ms, min_ms, max_ms, usa_indice, acessos)
    SELECT p_fase, q.nome, p_repeticoes,
           round(v_tot / p_repeticoes, 2), round(v_min, 2), round(v_max, 2),
           jsonb_path_exists(v_plan, 'strict $.** ? (@."Node Type" like_regex "Index")'),
           (SELECT string_agg(DISTINCT (x->>'Node Type') || ' em ' || (x->>'Relation Name'), '; ')
            FROM jsonb_path_query(v_plan, 'strict $.**') x
            WHERE jsonb_typeof(x) = 'object' AND x ? 'Relation Name');
  END LOOP;
END
$fn$;

-- Comparativo: última medição 'antes' x última 'depois' de cada consulta
CREATE OR REPLACE VIEW monitor.vw_benchmark_comparativo AS
WITH ult AS (
  SELECT DISTINCT ON (fase, consulta) *
  FROM monitor.benchmark
  ORDER BY fase, consulta, executado_em DESC
)
SELECT a.consulta,
       a.media_ms AS antes_ms,
       d.media_ms AS depois_ms,
       round(100 * (1 - d.media_ms / nullif(a.media_ms, 0)), 1) AS ganho_pct,
       round(a.media_ms / nullif(d.media_ms, 0), 1)             AS vezes_mais_rapida,
       a.acessos AS plano_antes,
       d.acessos AS plano_depois
FROM ult a
LEFT JOIN ult d ON d.consulta = a.consulta AND d.fase = 'depois'
WHERE a.fase = 'antes'
ORDER BY ganho_pct DESC NULLS LAST;

-- Índices criados pelo projeto: tamanho e quantas vezes foram usados
CREATE OR REPLACE VIEW monitor.vw_indices_criados AS
SELECT s.relname                                      AS tabela,
       s.indexrelname                                 AS indice,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamanho,
       s.idx_scan                                     AS vezes_usado
FROM pg_stat_user_indexes s
WHERE s.schemaname = 'varejo'
  AND s.indexrelname LIKE 'idx\_%'
ORDER BY pg_relation_size(s.indexrelid) DESC;

GRANT SELECT ON monitor.benchmark, monitor.vw_benchmark_comparativo, monitor.vw_indices_criados TO monitor_user;
