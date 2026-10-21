# monitor-db-ia

Laboratório de monitoramento de bancos de dados com IA: Docker + PostgreSQL + n8n + Claude, com evolução para Databricks e BI.

## Arquitetura (etapa 1)

```
[carga] --queries de varejo--> [postgres-lab :5433] <--top queries + EXPLAIN-- [n8n :5678]
                                        ^                                          |
                                        |                                          v
                                 monitor.analises_ia <------ diagnóstico ---- [ollama :11434]
```

Base fictícia de varejo de moda (schema `varejo`): lojas, produtos, clientes, vendas,
itens de venda, estoque, transferências e inventários. Nenhum dado real.
A IA roda localmente (Ollama + qwen2.5:3b), de graça e sem dados saindo da máquina.

## Como subir

1. Copie `.env.example` para `.env` e troque as senhas.
2. Na pasta do projeto:
   ```
   docker compose up -d
   docker compose --profile carga up -d
   ```
3. Acesse o n8n em http://localhost:5678 e crie o usuário local.
4. Confira as queries lentas:
   ```
   docker exec -it postgres-lab psql -U labadmin -d lab -c "SELECT queryid, calls, mean_exec_ms, left(query,80) FROM monitor.vw_top_lentas;"
   ```

## Credencial do Postgres no n8n

- Host: `postgres-lab` | Porta: `5432` | Banco: `lab`
- Usuário: `monitor_user` | Senha: a `MONITOR_PASSWORD` do `.env`

## Roadmap

- [x] Etapa 1: Postgres com pg_stat_statements, carga de queries lentas, n8n
- [x] Etapa 2: base de varejo fictícia + fluxo n8n (top queries + EXPLAIN -> Ollama -> histórico)
- [x] Etapa 2b: pré-análise no banco (fn_pistas) para guiar a IA
- [x] Etapa 2c: benchmark antes/depois com EXPLAIN ANALYZE
- [x] Etapa 2d: Top SKUs resolvido com tabela pré-agregada (materialized view + refresh pelo n8n)
- [x] Etapa 3: dashboard no Grafana (http://localhost:3000) e fluxo de alerta no Telegram
- [ ] Etapa 3c: opção de usar a API do Claude no lugar do Ollama
- [ ] Etapa 3b: histórico em monitor.snapshot_queries e envio ao Databricks
- [x] Etapa 4: camada de BI (schema `bi`, modelo estrela) + guia e medidas DAX do Power BI (docs/powerbi)
- [ ] Etapa 5: Oracle Free e MySQL no lab

## Dashboard (Grafana)

http://localhost:3000 abre direto o painel "Monitor DB IA - Varejo" (visualização sem login;
para editar, usuário `admin` e a senha `GRAFANA_PASSWORD` do `.env`).

## Fluxos do n8n (pasta n8n/workflows)

| Arquivo | O que faz |
|---|---|
| analisador-queries-ollama.json | A cada 30 min: top queries lentas + plano + pistas -> IA -> monitor.analises_ia |
| alertas-telegram.json | A cada 15 min: envia no Telegram as análises ainda não avisadas |
| atualizar-preagregados.json | A cada hora: REFRESH da materialized view de ranking de SKUs |

## Benchmark antes/depois

```
docker compose --profile carga stop carga
docker exec postgres-lab psql -U labadmin -d lab -c "SELECT monitor.fn_benchmark('antes');"
docker exec postgres-lab psql -U labadmin -d lab -f /scripts/aplicar_indices.sql
docker exec postgres-lab psql -U labadmin -d lab -c "SELECT monitor.fn_benchmark('depois');"
docker exec postgres-lab psql -U labadmin -d lab -c "SELECT consulta, antes_ms, depois_ms, ganho_pct FROM monitor.vw_benchmark_comparativo;"
```

Top SKUs (correção por modelagem, não por índice): `docker exec postgres-lab psql -U labadmin -d lab -f /scripts/top_skus_preagregado.sql`

Para repetir a demonstração: `docker exec postgres-lab psql -U labadmin -d lab -f /scripts/reverter_indices.sql`

## Parar / limpar

```
docker compose --profile carga down        # para tudo
docker compose --profile carga down -v     # para e APAGA os dados (volumes)
```
