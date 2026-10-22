"""
Coletor multibanco -> monitor (PostgreSQL).

A cada INTERVALO_SEG lê, em cada banco cadastrado em monitor.ambientes
(coletar = true, banco MYSQL / SQLSERVER / MONGODB), as queries mais lentas
com o plano e as pistas e grava em monitor.lentas. A cada 30 minutos grava
também a saúde do schema (todos os bancos, PostgreSQL incluído) em
monitor.saude_schema. Banco fora do ar é só registrado no log.
"""
import os
import time
from datetime import datetime

import psycopg

from multibanco import CONECTORES

PG_DSN = os.environ.get("PG_DSN_OVERRIDE") or (
    f"host=postgres-lab dbname={os.environ['POSTGRES_DB']} user=monitor_user password={os.environ['MONITOR_PASSWORD']}")
INTERVALO = int(os.environ.get("INTERVALO_SEG", "300"))
SAUDE_A_CADA = int(os.environ.get("SAUDE_SEG", "1800"))
anteriores = {}
ultima_saude = 0.0


def log(msg):
    print(f"{datetime.now():%H:%M:%S} {msg}", flush=True)


def gravar_saude(pg, banco, ambiente, achados):
    pg.execute("DELETE FROM monitor.saude_schema WHERE banco = %s AND ambiente = %s", (banco, ambiente))
    with pg.cursor() as cur:
        cur.executemany("INSERT INTO monitor.saude_schema (banco, ambiente, tipo, objeto, detalhe, tamanho_mb) "
                        "VALUES (%s, %s, %s, %s, %s, %s)", [(banco, ambiente, *a) for a in achados])


def ciclo():
    global ultima_saude
    fazer_saude = time.time() - ultima_saude >= SAUDE_A_CADA
    with psycopg.connect(PG_DSN, autocommit=True) as pg:
        ambs = pg.execute("""SELECT ambiente, banco, host, porta, nome_banco FROM monitor.ambientes
                             WHERE ativo AND coletar AND banco IN ('MYSQL', 'SQLSERVER', 'MONGODB')""").fetchall()
        for ambiente, banco, host, porta, nome in ambs:
            amb = {"host": host, "porta": porta, "nome_banco": nome}
            try:
                con = CONECTORES[banco](amb)
            except Exception as e:  # noqa: BLE001
                log(f"{banco} {ambiente} indisponível ({type(e).__name__}); pulando")
                continue
            try:
                lentas, atual = con.top_lentas(anteriores.get((banco, ambiente)))
                if atual is not None:
                    anteriores[(banco, ambiente)] = atual
                for r in lentas:
                    pg.execute("""
                        INSERT INTO monitor.lentas (banco, ambiente, query_id, query, calls, mean_exec_ms, plano, pistas, atualizado_em)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())
                        ON CONFLICT (banco, ambiente, query_id) DO UPDATE
                        SET query = EXCLUDED.query, calls = EXCLUDED.calls, mean_exec_ms = EXCLUDED.mean_exec_ms,
                            plano = EXCLUDED.plano, pistas = EXCLUDED.pistas, atualizado_em = now()""",
                        (banco, ambiente, r["query_id"], r["query"], r["calls"], r["mean_exec_ms"], r["plano"], r["pistas"]))
                msg = f"{banco} {ambiente}: {len(lentas)} queries lentas"
                if fazer_saude:
                    achados = con.saude()
                    gravar_saude(pg, banco, ambiente, achados)
                    msg += f", {len(achados)} achados de schema"
                log(msg)
            except Exception as e:  # noqa: BLE001 - mantém o coletor vivo
                log(f"{banco} {ambiente} erro na coleta: {e}")
            finally:
                con.close()
        if fazer_saude:
            achados = pg.execute("SELECT tipo, objeto, detalhe, tamanho_mb FROM monitor.vw_saude_postgres").fetchall()
            gravar_saude(pg, "POSTGRES", "PRD", achados)
            log(f"POSTGRES PRD: {len(achados)} achados de schema")
            ultima_saude = time.time()


if __name__ == "__main__":
    while True:
        try:
            ciclo()
        except Exception as e:  # noqa: BLE001
            log(f"erro no ciclo: {e}")
        time.sleep(INTERVALO)
