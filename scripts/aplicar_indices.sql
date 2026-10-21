-- Cria os índices sugeridos nas análises (monitor.analises_ia), do jeito
-- que seria feito em produção: CONCURRENTLY, sem travar escrita na tabela.
-- Uso: docker exec postgres-lab psql -U labadmin -d lab -f /scripts/aplicar_indices.sql
\echo 'Indices que serao criados:'
SELECT DISTINCT replace(substr(linha, 3), 'CREATE INDEX ', 'CREATE INDEX CONCURRENTLY IF NOT EXISTS ') AS comando
FROM monitor.analises_ia a,
     regexp_split_to_table(a.pistas, E'\n') AS linha
WHERE linha LIKE '- CREATE INDEX%'
\gexec
\echo 'Atualizando estatisticas...'
ANALYZE varejo.vendas;
ANALYZE varejo.itens_venda;
ANALYZE varejo.estoque;
ANALYZE varejo.transferencias;
ANALYZE varejo.inventario_itens;
SELECT * FROM monitor.vw_indices_criados;
