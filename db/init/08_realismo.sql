-- =====================================================================
-- Deixa a base fictícia com cara de varejo real, para o BI contar uma
-- história. Pode ser rodado num banco já existente (rodar uma vez só).
--  * Sazonalidade: pico na Black Friday, no Natal e no Dia das Mães
--  * Ruptura diferente por departamento e pior nas lojas do Norte/Nordeste
--  * Algumas lojas com inventário ruim (acuracidade baixa)
--  * Transferências atrasadas concentradas em lojas longe dos CDs
-- =====================================================================
DO $$ BEGIN PERFORM setseed(0.7); END $$;

-- 1) Sazonalidade: move ~22% das vendas para as datas de pico
UPDATE varejo.vendas v
SET data_hora = x.nova
FROM (
  SELECT id,
         CASE
           WHEN r < 0.10 THEN timestamptz '2025-11-24' + random() * interval '7 days'   -- semana da Black Friday
           WHEN r < 0.18 THEN timestamptz '2025-12-10' + random() * interval '14 days'  -- Natal
           ELSE              timestamptz '2026-05-01' + random() * interval '10 days'   -- Dia das Mães
         END AS nova
  FROM (SELECT id, random() AS r FROM varejo.vendas) s
  WHERE r < 0.22
) x
WHERE x.id = v.id;

-- 2) Ruptura por departamento (moda feminina e calçados giram mais rápido)
--    e com peso maior nas lojas do Norte e Nordeste
UPDATE varejo.estoque e
SET qtd_disponivel = CASE
      WHEN random() < (CASE p.departamento
                         WHEN 'FEMININO'   THEN 0.11
                         WHEN 'CALCADOS'   THEN 0.09
                         WHEN 'MASCULINO'  THEN 0.06
                         WHEN 'INFANTIL'   THEN 0.05
                         WHEN 'ACESSORIOS' THEN 0.04
                         ELSE 0.02 END)
                     * (CASE WHEN l.regiao IN ('Norte', 'Nordeste') THEN 1.6 ELSE 1.0 END)
      THEN 0
      ELSE greatest(e.qtd_disponivel, 1 + floor(random() * 40)::int)
    END
FROM varejo.produtos p, varejo.lojas l
WHERE p.id = e.produto_id
  AND l.id = e.loja_id;

-- 3) Inventário: 15 lojas com problema (≈25% de itens divergentes), demais ≈4%
UPDATE varejo.inventario_itens ii
SET qtd_contada = CASE
      WHEN random() < CASE WHEN i.loja_id % 13 = 0 THEN 0.25 ELSE 0.04 END
      THEN greatest(ii.qtd_sistema - 1 - floor(random() * 4)::int, 0)
      ELSE ii.qtd_sistema
    END
FROM varejo.inventarios i
WHERE i.id = ii.inventario_id;

-- 4) Transferências: lojas do Norte/Nordeste com mais atraso e lead time maior
UPDATE varejo.transferencias t
SET status = CASE WHEN random() < 0.30 THEN 'EM_TRANSITO' ELSE t.status END,
    dt_recebimento = CASE WHEN t.dt_recebimento IS NOT NULL
                          THEN t.dt_solicitacao + (3 + random() * 12) * interval '1 day' END
FROM varejo.lojas l
WHERE l.id = t.loja_destino
  AND l.regiao IN ('Norte', 'Nordeste');

UPDATE varejo.transferencias
SET dt_recebimento = NULL
WHERE status <> 'RECEBIDA';

ANALYZE varejo.vendas;
ANALYZE varejo.estoque;
ANALYZE varejo.inventario_itens;
ANALYZE varejo.transferencias;
