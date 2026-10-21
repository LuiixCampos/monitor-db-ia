-- Remove os índices criados pelo projeto (nomes idx_*), para repetir a demonstração.
-- Uso: docker exec postgres-lab psql -U labadmin -d lab -f /scripts/reverter_indices.sql
SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I', schemaname, indexname)
FROM pg_indexes
WHERE schemaname = 'varejo'
  AND indexname LIKE 'idx\_%'
\gexec
