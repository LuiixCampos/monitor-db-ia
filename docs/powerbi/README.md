# Relatório Power BI

O Power BI lê o schema `bi` do Postgres do lab (views em modelo estrela, criadas por `db/init/07_bi.sql`).
Nenhuma tabela do sistema é lida diretamente.

## 1. Conectar

1. Power BI Desktop > **Obter dados > Banco de dados PostgreSQL**
2. Servidor: `localhost:5433` | Banco de dados: `lab` | Modo: **Importar**
3. Credencial: aba **Banco de dados**, usuário `monitor_user`, senha `MONITOR_PASSWORD` do `.env`
4. Se aparecer aviso de criptografia/SSL, clique em **OK** para conectar sem criptografia (é um lab local)
5. No Navegador, marque todas as views do schema **bi** e clique em **Carregar**

## 2. Relacionamentos e medidas (atalho: TMDL)

Depois de carregar, abra a **Exibição TMDL**, cole o conteúdo de `modelo-relacoes-e-medidas.tmdl` e clique em **Aplicar**:
ele cria os relacionamentos com a dim_data e a loja de destino das transferências, e as 24 medidas (organizadas em pastas).
Os avisos "Cannot find name" antes de aplicar são normais (as medidas se referenciam entre si).
Depois, exclua o relacionamento inativo fato_itens_venda[venda_id] -> fato_vendas[venda_id], se o Power BI tiver criado.

### Lista completa dos relacionamentos

| De (muitos) | Para (um) |
|---|---|
| fato_vendas[loja_id] | dim_loja[loja_id] |
| fato_vendas[cliente_id] | dim_cliente[cliente_id] |
| fato_vendas[data] | dim_data[data] |
| fato_itens_venda[loja_id] | dim_loja[loja_id] |
| fato_itens_venda[produto_id] | dim_produto[produto_id] |
| fato_itens_venda[data] | dim_data[data] |
| fato_estoque[loja_id] | dim_loja[loja_id] |
| fato_estoque[produto_id] | dim_produto[produto_id] |
| fato_transferencias[loja_destino] | dim_loja[loja_id] |
| fato_transferencias[produto_id] | dim_produto[produto_id] |
| fato_transferencias[data_solicitacao] | dim_data[data] |
| fato_inventario[loja_id] | dim_loja[loja_id] |
| fato_inventario[produto_id] | dim_produto[produto_id] |
| fato_inventario[data] | dim_data[data] |

Todos com cardinalidade **muitos para um** e filtro em **direção única**.
Marque `dim_data` como tabela de datas (botão direito > Marcar como tabela de datas > coluna `data`).

## 3. Medidas

Cole as medidas de `medidas.dax`.

## 4. Páginas

O relatório ficou focado no monitoramento do banco. As views de negócio (`fato_*`, `dim_*`) continuam no schema
`bi` para quem quiser montar páginas de vendas ou estoque.

| Página | Visuais |
|---|---|
| **Performance do banco** | Barras agrupadas: mon_benchmark antes_ms x depois_ms por consulta. Cartão: Ganho Medio Benchmark %. Tabela: mon_analises_ia (analisado_em, mean_exec_ms, analise). |
| **Chamados** | Fila do Jira (mon_chamados), prioridade, status e horas em aberto. Ganho das correções (mon_correcoes). |
| **Bancos e saúde do schema** (sugerida) | Tabela: mon_lentas (banco, query, mean_exec_ms). Tabela: mon_saude_schema (banco, tipo, objeto, tamanho_mb). Cartões: chamados e ganho médio de mon_efetividade. |
| **Previsão** (sugerida) | Tabela: mon_previsao (banco, situacao, atual_ms, dias_ate_alta), ordenada por dias_ate_alta. |
| **Esteira HML -> PRD** (sugerida) | Tabela: mon_esteira (jira_key, etapa, hml_ganho_pct, prd_ganho_pct, paridade). Segmentação: mon_correcoes[ambiente]. |

## Observação

Modo **Importar**: os dados ficam no arquivo .pbix e só mudam ao clicar em **Atualizar**.
O .pbix não vai para o GitHub (arquivo binário grande); para versionar, salve como **Projeto do Power BI (.pbip)**.
