# monitor-db-ia

Laboratório de monitoramento de bancos de dados com IA: Docker + PostgreSQL + n8n + Claude, com evolução para Databricks e BI.

## Arquitetura (etapa 1)

```
[carga] --queries lentas--> [postgres-lab :5433] <--coleta pg_stat_statements-- [n8n :5678]
                                                                                    |
                                                         (etapa 2) Claude API --> Telegram
```

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
- [ ] Etapa 2: fluxo n8n coleta top queries + EXPLAIN, envia ao Claude, alerta no Telegram
- [ ] Etapa 3: histórico em monitor.snapshot_queries e envio ao Databricks
- [ ] Etapa 4: dashboard de BI (evolução de performance antes/depois)
- [ ] Etapa 5: Oracle Free e MySQL no lab

## Parar / limpar

```
docker compose --profile carga down        # para tudo
docker compose --profile carga down -v     # para e APAGA os dados (volumes)
```
