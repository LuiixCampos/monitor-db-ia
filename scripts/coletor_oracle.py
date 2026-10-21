"""
Coletor Oracle -> monitor (PostgreSQL).
A cada 5 minutos lê o top SQL lento do V$SQL (monitor_user.vw_top_lentas),
gera o plano com DBMS_XPLAN, calcula as pistas (TABLE ACCESS FULL em tabela
grande + colunas de filtro) e grava em monitor.oracle_lentas.
"""
import os
import re
import time

import oracledb
import psycopg

oracledb.defaults.fetch_lobs = False

ORA_DSN = os.environ.get("ORA_DSN", "oracle-lab:1521/FREEPDB1")
ORA_USER = "monitor_user"
ORA_PWD = os.environ["MONITOR_PASSWORD"]
PG_DSN = (f"host=postgres-lab dbname={os.environ['POSTGRES_DB']} "
          f"user=monitor_user password={os.environ['MONITOR_PASSWORD']}")
INTERVALO = int(os.environ.get("INTERVALO_SEG", "300"))
MIN_LINHAS = 50000


def pistas_oracle(plano: str, linhas_por_tabela: dict) -> str:
    """Lê o plano do DBMS_XPLAN e monta o texto de pistas."""
    full = {}   # id do passo -> tabela
    for m in re.finditer(r"\|\*?\s*(\d+)\s*\|\s*TABLE ACCESS (?:STORAGE )?FULL\s*\|\s*(\w+)", plano):
        full[m.group(1)] = m.group(2).upper()

    filtros = {}
    for m in re.finditer(r"^\s*(\d+)\s*-\s*filter\((.*)\)\s*$", plano, re.M):
        filtros[m.group(1)] = m.group(2)

    achados, candidatos = [], []
    for passo, tabela in full.items():
        linhas = linhas_por_tabela.get(tabela, 0)
        if linhas < MIN_LINHAS:
            continue
        filtro = filtros.get(passo)
        achados.append(f"- TABLE ACCESS FULL em VAREJO.{tabela} (~{linhas} linhas)"
                       + (f", filtro: {filtro}" if filtro else ", sem filtro (tabela lida inteira)"))
        if not filtro:
            continue
        cols = []
        for pred in re.split(r"\s+AND\s+", filtro):
            if "<>" in pred or " OR " in pred.upper():
                continue
            m = re.search(r'"(\w+)"(?:\."(\w+)")?\s*(=|>=|<=|>|<)', pred)
            if m:
                col = (m.group(2) or m.group(1)).upper()
                if col not in cols:
                    cols.append(col)
        cols.sort(key=lambda c: 0 if re.search(rf'"{c}"\s*=', filtro) else 1)
        if cols:
            nome = f"IDX_{tabela}_{'_'.join(cols)}"[:128]
            candidatos.append(f"- CREATE INDEX VAREJO.{nome} ON VAREJO.{tabela} ({', '.join(cols)}) ONLINE;")

    return ("PISTAS DO PLANO:\n" + ("\n".join(achados) or "- nenhum TABLE ACCESS FULL em tabela grande")
            + "\n\nCANDIDATOS A INDICE:\n"
            + ("\n".join(candidatos) or "- nenhum candidato obvio (avaliar reescrita da query)"))


def coletar():
    with oracledb.connect(user=ORA_USER, password=ORA_PWD, dsn=ORA_DSN) as ora, \
         psycopg.connect(PG_DSN, autocommit=True) as pg:
        cur = ora.cursor()
        cur.execute("SELECT table_name, NVL(num_rows, 0) FROM all_tables WHERE owner = 'VAREJO'")
        linhas = {t: n for t, n in cur.fetchall()}

        cur.execute("SELECT sql_id, calls, mean_exec_ms, query FROM monitor_user.vw_top_lentas")
        top = cur.fetchall()
        for sql_id, calls, mean_ms, query in top:
            cur.execute("SELECT monitor_user.fn_plano(:id) FROM dual", id=sql_id)
            plano = cur.fetchone()[0] or ""
            pg.execute("""
                INSERT INTO monitor.oracle_lentas (sql_id, query, calls, mean_exec_ms, plano, pistas, atualizado_em)
                VALUES (%s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (sql_id) DO UPDATE
                SET calls = EXCLUDED.calls, mean_exec_ms = EXCLUDED.mean_exec_ms,
                    plano = EXCLUDED.plano, pistas = EXCLUDED.pistas, atualizado_em = now()""",
                (sql_id, query, calls, mean_ms, plano, pistas_oracle(plano, linhas)))
        print(f"{time.strftime('%H:%M:%S')} coletadas {len(top)} queries lentas do Oracle", flush=True)


if __name__ == "__main__":
    while True:
        try:
            coletar()
        except Exception as e:  # noqa: BLE001 - mantém o coletor vivo
            print(f"erro na coleta: {e}", flush=True)
        time.sleep(INTERVALO)
