"""
Executor de correções aprovadas (chamado pelo n8n).

POST /aplicar  {"jira_key": "MDB-1"}
  1. Busca a análise do chamado (banco, pistas, query, tempo antes)
  2. Cria os índices candidatos:
       PostgreSQL -> CREATE INDEX CONCURRENTLY IF NOT EXISTS
       Oracle     -> CREATE INDEX ... ONLINE
  3. Zera as estatísticas da query, espera a carga rodar e mede de novo
  4. Grava em monitor.correcoes e devolve o resultado em JSON

Só escuta na rede interna do Docker (porta não publicada no host).
"""
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

ESPERA = int(os.environ.get("ESPERA_SEG", "120"))
PG_DSN = (f"host=postgres-lab dbname={os.environ['POSTGRES_DB']} "
          f"user={os.environ['POSTGRES_USER']} password={os.environ['POSTGRES_PASSWORD']}")
PG_HOST_DSN = os.environ.get("PG_DSN_OVERRIDE")  # usado só em teste
ORA_DSN = os.environ.get("ORA_DSN", "oracle-lab:1521/FREEPDB1")


def pg():
    return psycopg.connect(PG_HOST_DSN or PG_DSN, autocommit=True)


def comandos_das_pistas(pistas: str):
    return [l[2:].strip().rstrip(";") for l in (pistas or "").splitlines() if l.startswith("- CREATE INDEX")]


def aplicar_postgres(analise, cmds):
    executados = []
    with pg() as c:
        for cmd in cmds:
            cmd = re.sub(r"^CREATE INDEX\s+", "CREATE INDEX CONCURRENTLY IF NOT EXISTS ", cmd, flags=re.I)
            c.execute(cmd)
            executados.append(cmd)
        c.execute("ANALYZE varejo.vendas; ANALYZE varejo.itens_venda; ANALYZE varejo.estoque; "
                  "ANALYZE varejo.inventario_itens; ANALYZE varejo.transferencias;")
        c.execute("SELECT pg_stat_statements_reset(0, 0, %s)", (analise["queryid"],))
        time.sleep(ESPERA)
        row = c.execute("SELECT calls, round(mean_exec_time::numeric, 2) FROM pg_stat_statements "
                        "WHERE queryid = %s ORDER BY calls DESC LIMIT 1", (analise["queryid"],)).fetchone()
    depois = float(row[1]) if row and row[0] else None
    return executados, depois


def aplicar_oracle(analise, cmds):
    import oracledb
    executados = []
    with oracledb.connect(user="varejo", password=os.environ["ORACLE_APP_PASSWORD"], dsn=ORA_DSN) as ddl, \
         oracledb.connect(user="monitor_user", password=os.environ["MONITOR_PASSWORD"], dsn=ORA_DSN) as mon:
        t0 = mon.cursor().execute("SELECT SYSDATE FROM dual").fetchone()[0]
        cur = ddl.cursor()
        for cmd in cmds:
            try:
                cur.execute(cmd)
                executados.append(cmd)
            except oracledb.DatabaseError as e:
                if "ORA-00955" in str(e) or "ORA-01408" in str(e):   # índice já existe
                    executados.append(cmd + "  -- já existia")
                else:
                    raise
        time.sleep(ESPERA)
        row = mon.cursor().execute("""
            SELECT SUM(executions), ROUND(SUM(elapsed_time) / 1000 / NULLIF(SUM(executions), 0), 2)
            FROM v$sql
            WHERE sql_id = :id
              AND TO_DATE(last_load_time, 'YYYY-MM-DD/HH24:MI:SS') >= :t0""", id=analise["sql_id"], t0=t0).fetchone()
    depois = float(row[1]) if row and row[0] else None
    return executados, depois


def aplicar(jira_key: str) -> dict:
    with pg() as c:
        r = c.execute("""
            SELECT a.banco, a.queryid, a.sql_id, a.pistas, a.mean_exec_ms
            FROM monitor.chamados ch JOIN monitor.analises_ia a ON a.id = ch.analise_id
            WHERE ch.jira_key = %s""", (jira_key,)).fetchone()
        ja = c.execute("SELECT 1 FROM monitor.correcoes WHERE jira_key = %s AND resultado = 'OK'", (jira_key,)).fetchone()
    if not r:
        return {"ok": False, "jira_key": jira_key, "mensagem": "Chamado não encontrado no monitor."}
    if ja:
        return {"ok": False, "jira_key": jira_key, "mensagem": "Correção já aplicada antes."}

    analise = dict(zip(["banco", "queryid", "sql_id", "pistas", "antes"], r))
    banco = (analise["banco"] or "POSTGRES").upper()
    cmds = comandos_das_pistas(analise["pistas"])
    if not cmds:
        res = {"ok": False, "mensagem": "Sem índice candidato nas pistas; precisa revisar a query manualmente."}
        executados, depois = [], None
    else:
        try:
            executados, depois = (aplicar_oracle if banco == "ORACLE" else aplicar_postgres)(analise, cmds)
            res = {"ok": True}
        except Exception as e:  # noqa: BLE001
            executados, depois = [], None
            res = {"ok": False, "mensagem": f"Erro ao aplicar: {e}"}

    antes = float(analise["antes"]) if analise["antes"] is not None else None
    ganho = round(100 * (1 - depois / antes), 1) if (antes and depois is not None) else None
    res.update({"jira_key": jira_key, "banco": banco, "comandos": executados,
                "antes_ms": antes, "depois_ms": depois, "ganho_pct": ganho})
    if res["ok"]:
        res["mensagem"] = (f"Índice(s) criado(s). Tempo médio: {antes} ms -> {depois} ms ({ganho}% mais rápido)."
                           if depois is not None else
                           "Índice(s) criado(s), mas a query não rodou de novo no período de medição.")
    with pg() as c:
        c.execute("INSERT INTO monitor.correcoes (jira_key, banco, comandos, antes_ms, depois_ms, resultado, detalhe) "
                  "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                  (jira_key, banco, "\n".join(executados), antes, depois, "OK" if res["ok"] else "ERRO", res["mensagem"]))
    return res


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/aplicar":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        res = aplicar(str(body.get("jira_key", "")))
        print(json.dumps(res, ensure_ascii=False), flush=True)
        out = json.dumps(res, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    print(f"executor ouvindo na porta 8000 (espera de medição: {ESPERA}s)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
