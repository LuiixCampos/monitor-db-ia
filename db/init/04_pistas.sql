-- =====================================================================
-- Pré-análise feita pelo próprio banco, antes da IA.
-- Lê o plano de execução, encontra Seq Scans em tabelas grandes e
-- colunas de filtro/join sem índice, e monta os candidatos a índice.
-- A IA só explica e justifica; ela não precisa adivinhar.
-- Idempotente: pode ser rodado de novo num banco já existente.
-- =====================================================================

ALTER TABLE monitor.analises_ia ADD COLUMN IF NOT EXISTS pistas text;

-- true se a coluna já é a primeira coluna de algum índice da tabela
CREATE OR REPLACE FUNCTION monitor.fn_tem_indice(p_tabela text, p_coluna text) RETURNS boolean
LANGUAGE sql STABLE AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
    WHERE i.indrelid = p_tabela::regclass
      AND a.attname = p_coluna
  );
$fn$;

CREATE OR REPLACE FUNCTION monitor.fn_pistas(p_query text, p_min_linhas bigint DEFAULT 50000) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  v_txt   text;
  v_plan  jsonb;
  n       jsonb;
  m       text[];
  v_alias jsonb := '{}';   -- alias -> schema.tabela
  v_filt  jsonb := '{}';   -- tabela -> colunas de filtro sem índice
  v_join  jsonb := '{}';   -- tabela -> colunas de join sem índice
  v_seq   text := '';
  v_idx   text := '';
  v_cand  text := '';
  v_tab   text;
  v_rows  bigint;
  v_cols  text;
  k       text;
  arr     jsonb;
  c       text;
BEGIN
  p_query := regexp_replace(p_query, 'interval\s+(\$\d+)', '\1::interval', 'gi');
  EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ' || p_query INTO v_txt;
  v_plan := v_txt::jsonb;

  -- 1) Mapa alias -> tabela
  FOR n IN SELECT x FROM jsonb_path_query(v_plan, 'strict $.**') x
           WHERE jsonb_typeof(x) = 'object' AND x ? 'Relation Name' LOOP
    v_alias := v_alias || jsonb_build_object(n->>'Alias', format('%I.%I', n->>'Schema', n->>'Relation Name'));
  END LOOP;

  -- 2) Seq Scans em tabelas grandes e colunas do filtro sem índice
  FOR n IN SELECT x FROM jsonb_path_query(v_plan, 'strict $.**') x
           WHERE jsonb_typeof(x) = 'object' AND x->>'Node Type' = 'Seq Scan' LOOP
    v_tab := v_alias->>(n->>'Alias');
    SELECT reltuples::bigint INTO v_rows FROM pg_class WHERE oid = v_tab::regclass;
    CONTINUE WHEN v_rows < p_min_linhas;
    v_seq := v_seq || format(E'- Seq Scan em %s (~%s linhas)%s\n', v_tab, v_rows,
               coalesce(', filtro: ' || (n->>'Filter'), ', sem filtro (tabela lida inteira)'));
    -- Quebra o filtro em predicados (AND). Só aproveita predicados do tipo
    -- coluna = / >= / <= valor (uma coluna só, sem <> e sem OR).
    -- Igualdades primeiro, depois intervalos: é a ordem boa para índice composto.
    FOR c, m IN
      SELECT pred, (regexp_match(pred, '(\w+)\.(\w+)'))
      FROM regexp_split_to_table(coalesce(n->>'Filter', ''), '\s+AND\s+') WITH ORDINALITY f(pred, ord)
      ORDER BY (pred !~ '\s=\s'), ord
    LOOP
      CONTINUE WHEN m IS NULL OR m[1] <> n->>'Alias';
      CONTINUE WHEN (SELECT count(*) FROM regexp_matches(c, '(\w+)\.(\w+)', 'g')) <> 1;
      CONTINUE WHEN c ~ '<>' OR c ~* '\sOR\s';
      IF NOT monitor.fn_tem_indice(v_tab, m[2]) THEN
        v_filt := jsonb_set(v_filt, ARRAY[v_tab], coalesce(v_filt->v_tab, '[]') || to_jsonb(m[2]));
      END IF;
    END LOOP;
  END LOOP;

  -- 3) Colunas de join sem índice em tabelas grandes
  FOR n IN SELECT x FROM jsonb_path_query(v_plan, 'strict $.**') x
           WHERE jsonb_typeof(x) = 'object' AND x ?| ARRAY['Hash Cond', 'Merge Cond', 'Join Filter'] LOOP
    c := coalesce(n->>'Hash Cond', '') || ' ' || coalesce(n->>'Merge Cond', '') || ' ' || coalesce(n->>'Join Filter', '');
    -- Só interessa join entre duas tabelas grandes. Join com tabela pequena
    -- (ex.: produtos, lojas) se resolve bem com Hash Join, sem índice.
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM regexp_matches(c, '(\w+)\.(\w+)', 'g') r
      JOIN pg_class pc ON pc.oid = (v_alias->>r[1])::regclass
      WHERE pc.reltuples < p_min_linhas);
    FOR m IN SELECT regexp_matches(c, '(\w+)\.(\w+)', 'g') LOOP
      v_tab := v_alias->>m[1];
      CONTINUE WHEN v_tab IS NULL;
      IF NOT monitor.fn_tem_indice(v_tab, m[2]) THEN
        v_join := jsonb_set(v_join, ARRAY[v_tab], coalesce(v_join->v_tab, '[]') || to_jsonb(m[2]));
      END IF;
    END LOOP;
  END LOOP;

  -- 4) Índices que já existem nas tabelas grandes envolvidas
  SELECT string_agg(format('- %s: %s', t.tab,
           (SELECT string_agg(ix.indexname || ' (' || substring(ix.indexdef FROM '\((.*)\)') || ')', ', ')
            FROM pg_indexes ix
            WHERE format('%I.%I', ix.schemaname, ix.tablename) = t.tab)), E'\n')
  INTO v_idx
  FROM (SELECT DISTINCT value AS tab FROM jsonb_each_text(v_alias)) t
  JOIN pg_class pc ON pc.oid = t.tab::regclass
  WHERE pc.reltuples >= p_min_linhas;

  -- 5) Candidatos: um índice composto pelas colunas de filtro de cada tabela
  FOR k, arr IN SELECT * FROM jsonb_each(v_filt) LOOP
    SELECT string_agg(col, ', ' ORDER BY ord) INTO v_cols
    FROM (SELECT col, min(ord) AS ord FROM jsonb_array_elements_text(arr) WITH ORDINALITY e(col, ord) GROUP BY col) s;
    v_cand := v_cand || format(E'- CREATE INDEX idx_%s_%s ON %s (%s);\n',
                split_part(k, '.', 2), replace(v_cols, ', ', '_'), k, v_cols);
  END LOOP;

  --    e um índice por coluna de join (se já não for a 1a coluna de um candidato de filtro)
  FOR k, arr IN SELECT * FROM jsonb_each(v_join) LOOP
    FOR c IN SELECT DISTINCT col FROM jsonb_array_elements_text(arr) e(col) LOOP
      CONTINUE WHEN (v_filt->k->>0) = c;
      v_cand := v_cand || format(E'- CREATE INDEX idx_%s_%s ON %s (%s);\n', split_part(k, '.', 2), c, k, c);
    END LOOP;
  END LOOP;

  RETURN 'PISTAS DO PLANO:' || E'\n' || coalesce(nullif(v_seq, ''), E'- nenhum Seq Scan em tabela grande\n')
      || E'\nINDICES EXISTENTES:\n' || coalesce(v_idx, '- (nenhuma tabela grande envolvida)') || E'\n'
      || E'\nCANDIDATOS A INDICE:\n' || coalesce(nullif(v_cand, ''), E'- nenhum candidato obvio (avaliar reescrita da query)\n');
EXCEPTION WHEN others THEN
  RETURN 'Erro ao gerar pistas: ' || SQLERRM;
END
$fn$;
