# Relatório Power BI

O Power BI lê o schema `bi` do Postgres do lab (views em modelo estrela, criadas por `db/init/07_bi.sql`).
Nenhuma tabela do sistema é lida diretamente.

## 1. Conectar

1. Power BI Desktop > **Obter dados > Banco de dados PostgreSQL**
2. Servidor: `localhost:5433` | Banco de dados: `lab` | Modo: **Importar**
3. Credencial: aba **Banco de dados**, usuário `monitor_user`, senha `MONITOR_PASSWORD` do `.env`
4. Se aparecer aviso de criptografia/SSL, clique em **OK** para conectar sem criptografia (é um lab local)
5. No Navegador, marque todas as views do schema **bi** e clique em **Carregar**

## 2. Relacionamentos (Exibição de modelo)

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

## 4. Páginas sugeridas

| Página | Visuais |
|---|---|
| **Visão geral** | Cartões: Faturamento, Qtd Vendas, Ticket Medio, Margem Bruta %. Linha: Faturamento por dim_data[data]. Rosca: Faturamento por dim_loja[regiao]. Barras: Faturamento por fato_vendas[canal]. |
| **Produtos** | Barras: top 10 dim_produto[sku] por Pecas Vendidas. Matriz: departamento > categoria com Faturamento e Margem Bruta %. Segmentação: colecao. |
| **Lojas** | Mapa ou barras: Faturamento por dim_loja[cidade]. Tabela: loja, Faturamento, Ticket Medio, Pecas por Atendimento. Segmentação: regiao, tipo. |
| **Estoque e inventário** | Cartões: Estoque Valor Custo, Ruptura %, Acuracidade Inventario %, Transferencias Atrasadas. Barras: SKUs em Ruptura por loja. Tabela: Perda Inventario (custo) por loja. |
| **Performance do banco** | Barras agrupadas: mon_benchmark antes_ms x depois_ms por consulta. Cartão: Ganho Medio Benchmark %. Tabela: mon_analises_ia (analisado_em, mean_exec_ms, analise). |

## Observação

Modo **Importar**: os dados ficam no arquivo .pbix e só mudam ao clicar em **Atualizar**.
O .pbix não vai para o GitHub (arquivo binário grande); para versionar, salve como **Projeto do Power BI (.pbip)**.
