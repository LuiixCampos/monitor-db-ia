-- =====================================================================
-- Camada de BI: schema "bi" com views em modelo estrela (dimensões e
-- fatos) para o Power BI. O Power BI lê só daqui, nunca direto das
-- tabelas do sistema. Usuário de leitura: monitor_user.
-- Idempotente: pode ser rodado de novo num banco já existente.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS bi;

-- ---------- Dimensões ----------
CREATE OR REPLACE VIEW bi.dim_loja AS
SELECT id AS loja_id, codigo, nome AS loja, cidade, uf, regiao, tipo, data_abertura
FROM varejo.lojas;

CREATE OR REPLACE VIEW bi.dim_produto AS
SELECT id AS produto_id, sku, descricao, departamento, categoria, cor, tamanho, colecao,
       preco AS preco_venda, custo AS custo_unitario, ativo
FROM varejo.produtos;

CREATE OR REPLACE VIEW bi.dim_cliente AS
SELECT id AS cliente_id, nome AS cliente, cidade, uf, data_cadastro
FROM varejo.clientes;

-- Calendário dos últimos 3 anos até o fim do ano que vem
CREATE OR REPLACE VIEW bi.dim_data AS
SELECT d::date                                   AS data,
       extract(year FROM d)::int                 AS ano,
       extract(quarter FROM d)::int              AS trimestre,
       extract(month FROM d)::int                AS mes,
       (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[extract(month FROM d)::int] AS mes_nome,
       to_char(d, 'YYYY-MM')                     AS ano_mes,
       extract(isodow FROM d)::int               AS dia_semana_num,
       (ARRAY['Seg','Ter','Qua','Qui','Sex','Sab','Dom'])[extract(isodow FROM d)::int] AS dia_semana,
       extract(isodow FROM d) IN (6, 7)          AS fim_de_semana
FROM generate_series(date_trunc('year', now()) - interval '3 years',
                     date_trunc('year', now()) + interval '2 years' - interval '1 day',
                     interval '1 day') d;

-- ---------- Fatos ----------
-- Uma linha por venda (cupom)
CREATE OR REPLACE VIEW bi.fato_vendas AS
SELECT id AS venda_id, loja_id, cliente_id, data_hora::date AS data,
       extract(hour FROM data_hora)::int AS hora,
       canal, forma_pagamento, status, valor_total
FROM varejo.vendas;

-- Uma linha por item vendido, com custo para margem
CREATE OR REPLACE VIEW bi.fato_itens_venda AS
SELECT i.id AS item_id, i.venda_id, v.loja_id, i.produto_id, v.data_hora::date AS data,
       v.canal, v.status,
       i.quantidade,
       round(i.quantidade * i.preco_unitario - i.desconto, 2) AS valor_liquido,
       i.desconto,
       round(i.quantidade * p.custo, 2)                       AS custo_total
FROM varejo.itens_venda i
JOIN varejo.vendas v   ON v.id = i.venda_id
JOIN varejo.produtos p ON p.id = i.produto_id;

-- Foto atual do estoque
CREATE OR REPLACE VIEW bi.fato_estoque AS
SELECT e.loja_id, e.produto_id, e.qtd_disponivel, e.qtd_reservada,
       e.qtd_disponivel = 0                              AS em_ruptura,
       round(e.qtd_disponivel * p.custo, 2)              AS valor_estoque_custo,
       e.atualizado_em::date                             AS data_atualizacao
FROM varejo.estoque e
JOIN varejo.produtos p ON p.id = e.produto_id;

CREATE OR REPLACE VIEW bi.fato_transferencias AS
SELECT id AS transferencia_id, loja_origem, loja_destino, produto_id, quantidade, status,
       dt_solicitacao::date AS data_solicitacao,
       dt_recebimento::date AS data_recebimento,
       CASE WHEN dt_recebimento IS NOT NULL
            THEN round(extract(epoch FROM dt_recebimento - dt_solicitacao) / 86400.0, 1) END AS dias_ate_receber,
       status = 'EM_TRANSITO' AND dt_solicitacao < now() - interval '7 days' AS atrasada
FROM varejo.transferencias;

CREATE OR REPLACE VIEW bi.fato_inventario AS
SELECT ii.id AS item_inventario_id, i.id AS inventario_id, i.loja_id, ii.produto_id,
       i.data_inventario AS data,
       ii.qtd_sistema, ii.qtd_contada,
       ii.qtd_contada - ii.qtd_sistema                       AS diferenca,
       ii.qtd_contada <> ii.qtd_sistema                      AS divergente,
       round((ii.qtd_contada - ii.qtd_sistema) * p.custo, 2) AS diferenca_valor_custo
FROM varejo.inventario_itens ii
JOIN varejo.inventarios i ON i.id = ii.inventario_id
JOIN varejo.produtos p    ON p.id = ii.produto_id;

-- ---------- Monitoramento (página técnica do relatório) ----------
CREATE OR REPLACE VIEW bi.mon_benchmark AS
SELECT consulta, antes_ms, depois_ms, ganho_pct, vezes_mais_rapida, plano_antes, plano_depois
FROM monitor.vw_benchmark_comparativo;

CREATE OR REPLACE VIEW bi.mon_analises_ia AS
SELECT id, analisado_em, analisado_em::date AS data, queryid, mean_exec_ms, calls, modelo,
       analise, notificado_em IS NOT NULL AS notificado
FROM monitor.analises_ia;

CREATE OR REPLACE VIEW bi.mon_indices AS
SELECT * FROM monitor.vw_indices_criados;

GRANT USAGE ON SCHEMA bi TO monitor_user;
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO monitor_user;
