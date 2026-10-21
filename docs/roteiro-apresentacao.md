# Roteiro de apresentação - monitor-db-ia

Duração sugerida: 10 minutos. Público: gestor na NTT Data (primeiro) e, se aprovado, time do cliente.

## 1. O problema (1 min)

Em incidentes de lentidão, boa parte do tempo vai para achar a query culpada, ler o plano de execução e
decidir a correção. Isso depende de quem está de plantão e quase nunca fica registrado.

## 2. A proposta (1 min)

Um ciclo automático: detectar a query lenta, pré-analisar o plano, gerar um diagnóstico em linguagem clara,
sugerir a correção, medir o ganho e avisar o DBA. A decisão de aplicar continua sendo do DBA.

## 3. Demonstração (5 min)

1. Grafana: queries lentas do momento e diagnósticos gerados.
2. Telegram: alerta recebido com query, tempo médio e diagnóstico.
3. Power BI, página Performance do banco: ganho médio de 73% e consulta de 235 ms caindo para 0,04 ms.
4. Power BI, páginas Visão geral e Estoque: o mesmo banco servindo BI do negócio.

## 4. Segurança e custo (1 min)

- Base 100% fictícia; nenhum dado de cliente foi usado.
- IA rodando localmente: nenhum dado sai do ambiente.
- Ferramentas gratuitas (PostgreSQL, Oracle Free, n8n, Grafana, Ollama).
- O banco monitorado é acessado com usuário somente leitura de estatísticas.

## 5. Próximos passos propostos (1 min)

- Piloto em ambiente de homologação, com aprovação de segurança.
- Conectar ao Oracle de homologação via usuário de leitura (`V$SQL`, `DBMS_XPLAN`).
- Integrar o alerta ao canal já usado pelo time (Teams ou e-mail) em vez do Telegram.

## 6. Perguntas esperadas

- A IA pode errar? Pode. Por isso o banco faz a pré-análise e o benchmark comprova o ganho antes de qualquer mudança.
- Aplica índice sozinho? Não. Só sugere; aplicar é decisão do DBA, com `CREATE INDEX CONCURRENTLY` (ou `ONLINE` no Oracle).
- Quanto custa? Zero em licenças no lab; em produção, depende da ferramenta de IA homologada pela empresa.
