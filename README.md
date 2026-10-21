# monitor-db-ia

Laboratório de monitoramento de bancos de dados com IA: detecta queries lentas, gera um diagnóstico
automático, sugere a correção, comprova o ganho com benchmark e apresenta tudo em dashboards de BI.

Toda a base é fictícia (varejo de moda genérico) e a IA roda localmente, sem enviar dados para fora da máquina.

## O ciclo

```
detectar  ->  diagnosticar  ->  corrigir  ->  comprovar  ->  apresentar
pg_stat_statements   pré-análise do plano    CREATE INDEX      EXPLAIN ANALYZE     Grafana e Power BI
V$SQL (Oracle)       + IA local (Ollama)     CONCURRENTLY      antes x depois      + alerta no Telegram
```

## Arquitetura

```
[carga] ---> [postgres-lab :5433] <--- [n8n :5678] ---> [ollama :11434]
                   |   schema varejo      |  a cada 30 min: top queries + plano + pistas -> IA
                   |   schema monitor     |  a cada 15 min: alerta no Telegram
                   |   schema bi          |  a cada hora:   refresh das tabelas pré-agregadas
                   v
         [grafana :3000]  [Power BI Desktop]          [oracle-lab :1521]  (opcional)
```

| Componente | Papel |
|---|---|
| PostgreSQL 16 | Base de varejo (5 milhões de linhas), `pg_stat_statements`, schemas `monitor` e `bi` |
| Oracle Free 23ai | Mesma ideia no Oracle, com `V$SQL` e `DBMS_XPLAN` (perfil opcional) |
| n8n | Orquestra coleta, análise da IA, alertas e manutenção |
| Ollama (qwen2.5:3b) | IA local e gratuita que escreve o diagnóstico |
| Grafana | Painel operacional (queries lentas, diagnósticos, benchmark) |
| Power BI | Relatório gerencial: vendas, performance do banco, estoque e inventário |

## Resultados no lab

| Consulta | Antes | Depois | Correção |
|---|---|---|---|
| Top 20 SKUs do mês | 235 ms | 0,04 ms | Tabela pré-agregada (materialized view) |
| Vendas 24h por loja | 72 ms | 2,6 ms | Índice em `vendas(data_hora)` |
| Histórico do cliente | 25 ms | 0,01 ms | Índice em `vendas(cliente_id)` |
| Ruptura de estoque | 18 ms | 3,8 ms | Índice composto em `estoque(loja_id, qtd_disponivel)` |
| Divergência de inventário | 14 ms | 3,5 ms | Índice em `inventario_itens(inventario_id)` |

O diagnóstico da IA é guiado por uma pré-análise feita pelo próprio banco (`monitor.fn_pistas`), que lê o plano
de execução e aponta Seq Scans em tabelas grandes e colunas de filtro e join sem índice. Isso evita que um modelo
pequeno sugira índices inúteis.

## Como subir

1. Copie `.env.example` para `.env` e defina as senhas (somente letras e números).
2. Na pasta do projeto:
   ```
   docker compose up -d
   docker compose --profile carga up -d carga
   docker exec -it ollama ollama pull qwen2.5:3b
   ```
3. Importe os fluxos de `n8n/workflows` em http://localhost:5678 e selecione as credenciais.
4. Grafana em http://localhost:3000. Power BI: siga `docs/powerbi/README.md`.

Oracle (opcional, cerca de 2 GB de RAM):
```
docker compose --profile oracle up -d
```

## Estrutura

```
db/init/        scripts do PostgreSQL (base, monitoramento, pistas, benchmark, BI, realismo)
oracle/init/    scripts do Oracle (base e monitoramento)
scripts/        carga, aplicação e reversão de índices, pré-agregados
n8n/workflows/  fluxos do n8n (analisador, alertas, pré-agregados)
grafana/        datasource e dashboard provisionados
docs/powerbi/   guia, medidas DAX, tema e fundos do relatório
docs/           roteiro de apresentação
```

## Roadmap

- [x] Base de varejo fictícia e carga simulada
- [x] Detecção de queries lentas e pré-análise do plano no banco
- [x] Diagnóstico com IA local (Ollama) e alerta no Telegram
- [x] Benchmark antes/depois e correção por modelagem (pré-agregado)
- [x] Grafana e relatório Power BI (3 páginas)
- [x] Dados com sazonalidade e diferenças regionais
- [x] Oracle Free no lab (base e monitoramento)
- [ ] Fluxo do n8n para o Oracle
- [ ] Histórico no Databricks
- [ ] Opção de usar a API do Claude no lugar do Ollama
