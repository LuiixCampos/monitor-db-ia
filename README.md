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
- [ ] Etapa 2b: alerta no Telegram e opção de usar a API do Claude
- [ ] Etapa 3: histórico em monitor.snapshot_queries e envio ao Databricks
- [ ] Etapa 4: dashboard de BI (evolução de performance antes/depois)
- [ ] Etapa 5: Oracle Free e MySQL no lab

## Parar / limpar

```
docker compose --profile carga down        # para tudo
docker compose --profile carga down -v     # para e APAGA os dados (volumes)
```
