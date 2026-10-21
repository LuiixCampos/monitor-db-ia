# Roteiro de apresentação - monitor-db-ia

Duração sugerida: 12 minutos. Público: gestor na NTT Data (primeiro) e, se aprovado, time do cliente.

## Antes de começar (15 min antes)

```
docker compose up -d
docker compose --profile carga --profile oracle up -d
```

- Abra as abas: Grafana (localhost:3000), n8n (localhost:5678), Jira (fila MDB), Slack (#incidentes-db),
  painel do Databricks e o arquivo do Power BI.
- Deixe um chamado aberto no Jira **sem** a etiqueta `aprovado`. Ele é a demonstração ao vivo.
- Rode `scripts/reverter_indices.sql` antes, se quiser que a correção tenha ganho visível.

## 1. O problema (1 min)

Em incidentes de lentidão, boa parte do tempo vai para achar a query culpada, ler o plano de execução,
decidir a correção e registrar o chamado. Isso depende de quem está de plantão e quase nunca fica
documentado com antes e depois.

## 2. A proposta (1 min)

Um ciclo de ponta a ponta: detectar, diagnosticar, abrir o chamado, aprovar, corrigir, medir e prever.
O DBA continua decidindo; o lab faz o trabalho repetitivo e prova o resultado com números.

## 3. Demonstração (7 min)

1. **Grafana:** queries lentas do momento no PostgreSQL e no Oracle, com o diagnóstico da IA.
2. **Telegram e Slack:** alerta recebido e chamado avisado no canal com o link.
3. **Jira:** abra o chamado. Mostre o diagnóstico, as pistas do plano e o índice sugerido.
4. **Ao vivo:** adicione a etiqueta `aprovado`. Em até 5 minutos (ou execute o fluxo `aplicar-correcoes`
   no n8n), o índice é criado sem travar a tabela, o ganho é medido, o Jira recebe o comentário com
   antes x depois e o chamado é resolvido. O Slack recebe o aviso.
   - Enquanto espera, fale do item 5 (MDB-2: 53,8 ms para 1,6 ms, 97,1%).
5. **Power BI:** Visão geral, Performance (ganho por correção), Chamados (fila e SLA) e Estoque
   (o mesmo banco servindo o negócio).
6. **Databricks:** previsão. "Esta query hoje está em 214 ms e piora 1,6 ms por dia; esta outra, no
   Oracle, chega ao limite em cerca de 257 dias." Passa de reativo para preventivo.

## 4. Resultados (1 min)

- Ganho médio das correções: 66% (Databricks).
- MDB-2: 97,1%. MDB-3: 99,8%.
- MDB-1: o executor mediu ~1%, ou seja, índice não resolvia. A correção certa foi uma tabela
  pré-agregada (235 ms para 0,04 ms). A medição evita aplicar coisa que não funciona.

## 5. Segurança e custo (1 min)

- Base 100% fictícia; nenhum dado de cliente foi usado.
- IA local: nenhum dado sai do ambiente.
- Nada é aplicado sem aprovação no Jira; índices com `CONCURRENTLY` / `ONLINE`.
- Ferramentas gratuitas ou planos free (PostgreSQL, Oracle Free, n8n, Grafana, Ollama, Jira, Slack, Databricks Free).

## 6. Próximos passos propostos (1 min)

- Piloto em homologação, com usuário de leitura e aprovação de segurança.
- Avisos no Teams (canal do time) e fila no Jira/ServiceNow já usados no cliente.
- Trocar o Ollama pela IA homologada pela empresa.

## 7. Perguntas esperadas

- **A IA pode errar?** Pode. Por isso o banco faz a pré-análise do plano, o DBA aprova e o executor mede o ganho real.
- **Aplica índice sozinho?** Só depois da aprovação no Jira, e o registro fica no chamado.
- **E se piorar?** O antes e depois fica gravado; `scripts/reverter_indices.sql` desfaz.
- **Quanto custa?** Zero em licenças no lab; em produção depende das ferramentas homologadas.

## Ao final

```
docker compose --profile carga --profile oracle stop
```
