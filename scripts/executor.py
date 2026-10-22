"""
Executor de correções aprovadas (chamado pelo n8n).

Esteira DEV / HML / PRD (cadastro em monitor.ambientes):

POST /testar   {"jira_key": "MDB-1"}
  Etapa 1, depois da etiqueta 'aprovado' no Jira.
  1. Confere a paridade HML x PRD nas tabelas envolvidas (linhas e índices)
  2. Mede a query em HML (mesma base e mesma carga de PRD)
  3. Cria os índices candidatos em HML (CONCURRENTLY), espera a carga e mede de novo
  4. Libera para PRD só se o ganho em HML for >= GANHO_MIN_PCT
  Sem HML cadastrado para o banco (ex.: Oracle no lab), libera direto e avisa.

POST /aplicar  {"jira_key": "MDB-1"}
  Etapa 2, depois da etiqueta 'aplicar-prd' (mudança aprovada).
  Só aplica em PRD se o teste em HML liberou e se estiver dentro da JANELA_PRD.
       PostgreSQL -> CREATE INDEX CONCURRENTLY IF NOT EXISTS
       Oracle     -> CREATE INDEX ... ONLINE
       MySQL      -> CREATE INDEX ... ALGORITHM=INPLACE LOCK=NONE
       SQL Server -> CREATE INDEX ... WITH (ONLINE = ON)
       MongoDB    -> createIndex (build sem bloquear a coleção)
  Mede antes x depois em PRD e grava em monitor.correcoes.

Só escuta na rede interna do Docker (porta não publicada no host).
"""
import json
import os
import re
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from zoneinfo import ZoneInfo

import psycopg

from multibanco import CONECTORES

ESPERA = int(os.environ.get("ESPERA_SEG", "120"))
GANHO_MIN = float(os.environ.get("GANHO_MIN_PCT", "20"))
JANELA_PRD = os.environ.get("JANELA_PRD", "").strip()      # ex.: 22:00-06:00 (vazio = qualquer hora)
FUSO = ZoneInfo(os.environ.get("TZ", "America/Sao_Paulo"))
PG_USER = os.environ["POSTGRES_USER"]
PG_PWD = os.environ["POSTGRES_PASSWORD"]
PG_DSN = f"host=postgres-lab dbname={os.environ['POSTGRES_DB']} user={PG_USER} password={PG_PWD}"
PG_HOST_DSN = os.environ.get("PG_DSN_OVERRIDE")  # usado só em teste
ORA_DSN = os.environ.get("ORA_DSN", "oracle-lab:1521/FREEPDB1")


# ---------------------------------------------------------------- conexões
def pg():
    """Banco do monitor (fica no PRD do lab)."""
    return psycopg.connect(PG_HOST_DSN or PG_DSN, autocommit=True)


def ambiente(banco: str, nome: str):
    with pg() as c:
        r = c.execute("SELECT host, porta, nome_banco FROM monitor.ambientes "
                      "WHERE banco = %s AND ambiente = %s AND ativo", (banco, nome)).fetchone()
    return dict(zip(["host", "porta", "nome_banco"], r)) if r else None


def pg_amb(amb: dict):
    if PG_HOST_DSN and amb["host"] == "postgres-lab":
        return pg()
    return psycopg.connect(host=amb["host"], port=amb["porta"], dbname=amb["nome_banco"],
                           user=PG_USER, password=PG_PWD, autocommit=True)


# ---------------------------------------------------------------- utilidades
def comandos_das_pistas(pistas: str):
    return [l[2:].strip().rstrip(";") for l in (pistas or "").splitlines() if l.startswith("- CREATE INDEX")]


def tabelas_dos_comandos(cmds):
    return sorted({m.group(1).lower() for cmd in cmds for m in re.finditer(r"\bON\s+([\w.]+)", cmd, re.I)})


def concurrently(cmd: str) -> str:
    return re.sub(r"^CREATE INDEX\s+", "CREATE INDEX CONCURRENTLY IF NOT EXISTS ", cmd, flags=re.I)


def dentro_da_janela() -> bool:
    if not JANELA_PRD:
        return True
    ini, fim = [datetime.strptime(x.strip(), "%H:%M").time() for x in JANELA_PRD.split("-")]
    agora = datetime.now(FUSO).time()
    return ini <= agora < fim if ini < fim else (agora >= ini or agora < fim)   # janela que vira a noite


def ganho(antes, depois):
    return round(100 * (1 - depois / antes), 1) if (antes and depois is not None) else None


def medir_pg(c, query_texto: str, esperar: bool):
    """Tempo médio da query (texto normalizado) no pg_stat_statements do ambiente."""
    sql = ("SELECT s.queryid, s.calls, round(s.mean_exec_time::numeric, 2) FROM pg_stat_statements s "
           "JOIN pg_database d ON d.oid = s.dbid WHERE d.datname = current_database() "
           "AND s.toplevel AND s.query = %s ORDER BY s.calls DESC LIMIT 1")
    row = c.execute(sql, (query_texto,)).fetchone()
    if (not row or row[1] < 3) and esperar:
        time.sleep(ESPERA)
        row = c.execute(sql, (query_texto,)).fetchone()
    return (row[0], float(row[2])) if row and row[1] else (row[0] if row else None, None)


def paridade_pg(prd, hml, tabelas):
    """Diferenças de volume e de índices entre PRD e HML nas tabelas envolvidas."""
    avisos = []
    for t in tabelas:
        q_linhas = "SELECT reltuples::bigint FROM pg_class WHERE oid = to_regclass(%s)"
        q_idx = ("SELECT indexname, regexp_replace(indexdef, '^.* USING ', '') FROM pg_indexes "
                 "WHERE format('%%I.%%I', schemaname, tablename) = %s")
        lp, lh = prd.execute(q_linhas, (t,)).fetchone(), hml.execute(q_linhas, (t,)).fetchone()
        if not lh or lh[0] is None:
            avisos.append(f"{t}: não existe em HML")
            continue
        if lp and lp[0] and lp[0] > 0:
            dif = abs(lh[0] - lp[0]) / lp[0] * 100
            if dif > 20:
                avisos.append(f"{t}: HML tem {lh[0]} linhas e PRD {lp[0]} ({dif:.0f}% de diferença, o plano pode mudar)")
        ip = {d for _, d in prd.execute(q_idx, (t,)).fetchall()}
        ih = {d for _, d in hml.execute(q_idx, (t,)).fetchall()}
        for d in sorted(ip - ih):
            avisos.append(f"{t}: índice de PRD que falta em HML: {d}")
        for d in sorted(ih - ip):
            avisos.append(f"{t}: índice de HML que não existe em PRD: {d}")
    return avisos


def dados_do_chamado(jira_key: str):
    with pg() as c:
        r = c.execute("""
            SELECT coalesce(a.banco, 'POSTGRES'), a.queryid, a.sql_id, a.pistas, a.mean_exec_ms,
                   coalesce(a.query_texto, (SELECT s.query FROM pg_stat_statements s
                                            WHERE s.queryid = a.queryid ORDER BY s.toplevel DESC LIMIT 1))
            FROM monitor.chamados ch JOIN monitor.analises_ia a ON a.id = ch.analise_id
            WHERE ch.jira_key = %s""", (jira_key,)).fetchone()
    return dict(zip(["banco", "queryid", "sql_id", "pistas", "antes", "query"], r)) if r else None


def registrar(jira_key, banco, amb, cmds, antes, depois, ok, msg, liberado=None, paridade=None):
    with pg() as c:
        c.execute("INSERT INTO monitor.correcoes (jira_key, banco, ambiente, comandos, antes_ms, depois_ms, "
                  "resultado, detalhe, liberado, paridade) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                  (jira_key, banco, amb, "\n".join(cmds), antes, depois, "OK" if ok else "ERRO", msg,
                   liberado, "\n".join(paridade) if paridade else None))


# ---------------------------------------------------------------- etapa 1: HML
def testar(jira_key: str) -> dict:
    a = dados_do_chamado(jira_key)
    if not a:
        return {"ok": False, "liberado": False, "jira_key": jira_key, "mensagem": "Chamado não encontrado no monitor."}
    banco = a["banco"].upper()
    cmds = comandos_das_pistas(a["pistas"])
    base = {"jira_key": jira_key, "banco": banco, "ambiente": "HML", "comandos": cmds}
    if not cmds:
        return {**base, "ok": False, "liberado": False,
                "mensagem": "Sem índice candidato nas pistas; precisa revisar a query manualmente."}

    hml = ambiente(banco, "HML")
    if not hml:
        msg = f"Sem HML cadastrado para {banco}. Liberado para PRD sem teste prévio; aplicar só com mudança aprovada."
        registrar(jira_key, banco, "HML", [], None, None, True, msg, liberado=True)
        return {**base, "ok": True, "liberado": True, "sem_hml": True, "mensagem": msg}
    if banco != "POSTGRES":
        return {**base, "ok": False, "liberado": False, "mensagem": f"Teste em HML ainda não implementado para {banco}."}

    prd = ambiente(banco, "PRD")
    try:
        with pg_amb(prd) as cp, pg_amb(hml) as ch:
            avisos = paridade_pg(cp, ch, tabelas_dos_comandos(cmds))
            qid, antes = medir_pg(ch, a["query"], esperar=True)
            if antes is None:
                raise RuntimeError("a query não rodou em HML no período de medição (a carga-hml está ligada?)")
            executados = []
            for cmd in cmds:
                ch.execute(concurrently(cmd))
                executados.append(concurrently(cmd))
            for t in tabelas_dos_comandos(cmds):
                ch.execute(f"ANALYZE {t}")
            ch.execute("SELECT pg_stat_statements_reset(0, 0, %s)", (qid,))
            time.sleep(ESPERA)
            _, depois = medir_pg(ch, a["query"], esperar=False)
    except Exception as e:  # noqa: BLE001
        msg = f"Erro no teste em HML: {e}"
        registrar(jira_key, banco, "HML", [], None, None, False, msg)
        return {**base, "ok": False, "liberado": False, "mensagem": msg}

    g = ganho(antes, depois)
    liberado = g is not None and g >= GANHO_MIN
    if depois is None:
        msg = "Índice(s) criado(s) em HML, mas a query não rodou de novo no período de medição."
    elif liberado:
        msg = f"Testado em HML: {antes} ms -> {depois} ms ({g}% mais rápido). Liberado para PRD."
    else:
        msg = (f"Testado em HML: {antes} ms -> {depois} ms ({g}%). Ganho abaixo de {GANHO_MIN:.0f}%: "
               "índice não resolve, NÃO liberado para PRD. Avaliar reescrita ou modelagem.")
    if avisos:
        msg += "\nAtenção, diferenças entre HML e PRD:\n- " + "\n- ".join(avisos)
    registrar(jira_key, banco, "HML", executados, antes, depois, True, msg, liberado=liberado, paridade=avisos)
    return {**base, "ok": True, "liberado": liberado, "comandos": executados, "antes_ms": antes,
            "depois_ms": depois, "ganho_pct": g, "paridade": avisos, "mensagem": msg}


# ---------------------------------------------------------------- etapa 2: PRD
def aplicar_postgres(prd, analise, cmds):
    executados = []
    with pg_amb(prd) as c:
        for cmd in cmds:
            c.execute(concurrently(cmd))
            executados.append(concurrently(cmd))
        for t in tabelas_dos_comandos(cmds):
            c.execute(f"ANALYZE {t}")
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


def aplicar_multibanco(amb, banco, analise, cmds):
    con = CONECTORES[banco](amb, admin=True)
    try:
        executados = con.aplicar(cmds)
        marco = con.marco(analise["sql_id"])
        time.sleep(ESPERA)
        depois = con.medir(analise["sql_id"], marco)
    finally:
        con.close()
    return executados, depois


def aplicar(jira_key: str) -> dict:
    analise = dados_do_chamado(jira_key)
    if not analise:
        return {"ok": False, "jira_key": jira_key, "mensagem": "Chamado não encontrado no monitor."}
    banco = analise["banco"].upper()
    with pg() as c:
        ja = c.execute("SELECT 1 FROM monitor.correcoes WHERE jira_key = %s AND ambiente = 'PRD' AND resultado = 'OK'",
                       (jira_key,)).fetchone()
        teste = c.execute("SELECT liberado FROM monitor.correcoes WHERE jira_key = %s AND ambiente = 'HML' "
                          "AND resultado = 'OK' ORDER BY aplicado_em DESC LIMIT 1", (jira_key,)).fetchone()
    if ja:
        return {"ok": False, "jira_key": jira_key, "mensagem": "Correção já aplicada em PRD antes."}
    if not (teste and teste[0]):
        return {"ok": False, "jira_key": jira_key, "banco": banco,
                "mensagem": "Bloqueado: a correção não foi testada ou não foi liberada em HML."}
    if not dentro_da_janela():
        return {"ok": False, "adiado": True, "jira_key": jira_key, "banco": banco,
                "mensagem": f"Fora da janela de mudança de PRD ({JANELA_PRD}). Será aplicada na janela."}

    cmds = comandos_das_pistas(analise["pistas"])
    prd = ambiente(banco, "PRD")
    try:
        if banco == "ORACLE":
            executados, depois = aplicar_oracle(analise, cmds)
        elif banco in CONECTORES:
            executados, depois = aplicar_multibanco(prd, banco, analise, cmds)
        else:
            executados, depois = aplicar_postgres(prd, analise, cmds)
        res = {"ok": True}
    except Exception as e:  # noqa: BLE001
        executados, depois = [], None
        res = {"ok": False, "mensagem": f"Erro ao aplicar em PRD: {e}"}

    antes = float(analise["antes"]) if analise["antes"] is not None else None
    g = ganho(antes, depois)
    res.update({"jira_key": jira_key, "banco": banco, "ambiente": "PRD", "comandos": executados,
                "antes_ms": antes, "depois_ms": depois, "ganho_pct": g})
    if res["ok"]:
        res["mensagem"] = (f"Aplicado em PRD. Tempo médio: {antes} ms -> {depois} ms ({g}% mais rápido)."
                           if depois is not None else
                           "Aplicado em PRD, mas a query não rodou de novo no período de medição.")
    registrar(jira_key, banco, "PRD", executados, antes, depois, res["ok"], res["mensagem"])
    return res


# ---------------------------------------------------------------- HTTP
ROTAS = {"/testar": testar, "/aplicar": aplicar}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        fn = ROTAS.get(self.path)
        if not fn:
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        res = fn(str(body.get("jira_key", "")))
        print(json.dumps(res, ensure_ascii=False), flush=True)
        out = json.dumps(res, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    print(f"executor na porta 8000 (medição: {ESPERA}s, ganho mínimo em HML: {GANHO_MIN:.0f}%, "
          f"janela PRD: {JANELA_PRD or 'qualquer hora'})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
