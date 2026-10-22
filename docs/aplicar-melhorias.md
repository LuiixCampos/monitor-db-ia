# Aplicar as melhorias, passo a passo

Ordem pensada para não quebrar o que já funciona. Cada passo tem um teste no final; só siga para o
próximo quando o teste passar. Todos os comandos rodam na pasta do projeto.

## 0. Antes de começar

**Memória e disco.** Com tudo ligado o lab usa uns 12 GB de RAM e 12 GB de disco. No Docker Desktop
(WSL), aumente a memória criando `C:\Users\<você>\.wslconfig`:

```
[wsl2]
memory=12GB
```

Depois rode `wsl --shutdown` e abra o Docker Desktop de novo. Máquina mais fraca: use `ESCALA_BASE=0.3`
no `.env` (base menor) e ligue um banco extra por vez.

**`.env`.** Copie do `.env.example` as linhas novas e preencha:
`ESCALA_BASE`, `GANHO_MIN_PCT`, `JANELA_PRD`, `MSSQL_SA_PASSWORD` (maiúscula, minúscula e número),
`IA_PROVEDOR`, `IA_FALLBACK_OLLAMA` e, se for usar o Claude, `ANTHROPIC_API_KEY`.

## 1. Atualizar os serviços do PostgreSQL PRD

Recria o `postgres-lab` com a escala da base (os dados ficam), o executor novo e o gateway de IA:

```
docker compose up -d
```

**Teste:** `docker compose ps` mostra `postgres-lab`, `executor` e `ia-gateway` rodando.

## 2. Scripts novos no PRD

Rode na ordem. O 16 cria a base ampliada (~19 milhões de linhas) e leva uns 5 minutos; se der erro
no meio, nada fica pela metade.

```
docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/15_ambientes.sql
docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/16_base_ampliada.sql
docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/17_monitor_ampliado.sql
docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/18_multibanco.sql
docker exec postgres-lab psql -U labadmin -d lab -f /docker-entrypoint-initdb.d/19_previsao.sql
```

**Teste:** o 16 termina com uma tabela de linhas e tamanhos; `fiscal.notas_itens` com uns 4 milhões.

## 3. Carga com as consultas novas

```
docker compose --profile carga up -d --force-recreate carga
docker logs carga
```

**Teste:** o log mostra `Base ampliada: 1`.

## 4. HML

Na primeira subida o HML cria a mesma base de PRD (uns 7 minutos):

```
docker compose --profile hml up -d
docker logs -f postgres-hml
```

**Teste:** o log termina com `database system is ready to accept connections` e a `carga-hml` está rodando.

## 5. MySQL, SQL Server e MongoDB

Pode ligar um de cada vez. Na primeira subida cada um cria a sua base (2 a 6 minutos):

```
docker compose --profile mysql up -d
docker compose --profile sqlserver up -d
docker compose --profile mongodb up -d
```

**Teste:**
- `docker logs sqlserver-init` termina com `Base do cartão criada.`
- `docker logs carga-mysql`, `carga-sqlserver` e `carga-mongo` mostram `Iniciando carga...`
- Depois de uns 10 minutos, `docker logs coletor-multibanco` mostra linhas como `MYSQL PRD: 6 queries lentas`

## 6. n8n

Em http://localhost:5678:

1. **Importe os novos:** `testar-hml.json` e `analisador-queries-multibanco.json`.
2. **Reimporte (substituindo):** `aplicar-correcoes.json`, `alertas-telegram.json`,
   `analisador-queries-ollama.json` e `analisador-queries-oracle.json` (agora falam com o gateway de IA).
3. Coloque as credenciais nos nós (Postgres, Jira, Slack, Telegram) e ative todos.

**Teste:** execute o `analisador-queries-multibanco` manualmente; a tabela `monitor.analises_ia`
ganha linhas com `banco` = MYSQL, SQLSERVER ou MONGODB.

## 7. Grafana

```
docker compose restart grafana
```

**Teste:** o painel ganhou a linha "Multibanco, esteira HML -> PRD e previsão" (queries lentas de todos
os bancos, esteira, efetividade, previsão e saúde do schema).

## 8. Opcionais

**TimescaleDB** (histórico longo):
```
docker compose --profile timescale up -d
```
O painel "Monitor DB IA - Histórico (TimescaleDB)" aparece no Grafana depois do primeiro ciclo de cópia (15 min).

**IA do Claude:** no `.env`, `IA_PROVEDOR=claude` e a `ANTHROPIC_API_KEY`. Depois:
```
docker compose up -d ia-gateway
```
Teste: abra http://localhost:5678 e execute um analisador; ou `docker exec ia-gateway python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080').read())"`.

**Azure:** siga `deploy/azure/README.md`.

## 9. Teste de ponta a ponta

1. Espere os chamados novos no Jira (ou execute `chamados-jira` manualmente).
2. Num chamado do PostgreSQL, adicione `aprovado`. Em até 5 minutos o comentário traz o teste em HML
   e o chamado ganha `liberado-prd` (ou `revisar`).
3. Adicione `aplicar-prd`. Em até 5 minutos o índice é criado em PRD, o ganho é comentado e o chamado é resolvido.
4. Repita com um chamado do MySQL, do SQL Server e do MongoDB (eles pulam o HML e avisam no comentário).

## 10. Publicar

No GitHub Desktop, confira os arquivos alterados, faça o commit e clique em **Push origin**.
O `.env`, o `.pbix` e o `deploy/azure/parametros.json` ficam fora do Git.
