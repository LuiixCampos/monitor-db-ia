"""
Conectores do monitor para MySQL, SQL Server e MongoDB.

Cada banco sabe:
  top_lentas()          queries mais lentas, com plano e PISTAS (mesmo formato do PostgreSQL/Oracle)
  saude()               achados de schema: índice sem uso, duplicado, tabela sem PK, maiores tabelas
  aplicar(cmds)         cria os índices candidatos sem travar a tabela (usado pelo executor)
  marco(id) / medir()   mede o tempo médio da query depois de um marco (antes x depois)

Usado pelo coletor (scripts/coletor_multibanco.py) e pelo executor (scripts/executor.py).
"""
import hashlib
import json
import os
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

MIN_LINHAS = int(os.environ.get("MIN_LINHAS", "50000"))
LIMITE_MS = float(os.environ.get("LIMITE_MS", "20"))
MON_USER = "monitor_user"
MON_PWD = os.environ.get("MONITOR_PASSWORD", "")
ADMIN_USER = os.environ.get("POSTGRES_USER", "labadmin")
ADMIN_PWD = os.environ.get("POSTGRES_PASSWORD", "")
SA_PWD = os.environ.get("MSSQL_SA_PASSWORD", "")


def texto_pistas(achados, existentes, candidatos):
    return ("PISTAS DO PLANO:\n" + ("\n".join(achados) or "- nenhuma leitura completa em tabela grande")
            + "\n\nINDICES EXISTENTES:\n" + ("\n".join(existentes) or "- (nenhuma tabela grande envolvida)")
            + "\n\nCANDIDATOS A INDICE:\n"
            + ("\n".join(candidatos) or "- nenhum candidato obvio (avaliar reescrita da query)") + "\n")


def nome_indice(tabela, cols, limite=60):
    return re.sub(r"\W", "_", f"idx_{tabela}_{'_'.join(cols)}")[:limite]


def comandos_das_pistas(pistas: str):
    return [l[2:].strip().rstrip(";") for l in (pistas or "").splitlines() if l.startswith("- CREATE INDEX")]


# =====================================================================
# MySQL (performance_schema + EXPLAIN FORMAT=JSON)
# =====================================================================
class MySQL:
    banco = "MYSQL"

    def __init__(self, amb, admin=False):
        import pymysql
        self.db = amb["nome_banco"]
        self.c = pymysql.connect(host=amb["host"], port=int(amb["porta"]),
                                 user="root" if admin else MON_USER,
                                 password=ADMIN_PWD if admin else MON_PWD,
                                 database=self.db, connect_timeout=5, read_timeout=120, autocommit=True)
        self._anterior = {}

    def close(self):
        self.c.close()

    def q(self, sql, args=None):
        with self.c.cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall()

    # ---------------- coleta
    def top_lentas(self, anterior=None):
        """anterior: {digest: (count, sum_ps)} da coleta passada, para medir só o período recente."""
        rows = self.q("""
            SELECT DIGEST, QUERY_SAMPLE_TEXT, COUNT_STAR, SUM_TIMER_WAIT
            FROM performance_schema.events_statements_summary_by_digest
            WHERE (SCHEMA_NAME = %s OR DIGEST_TEXT LIKE %s)
              AND DIGEST_TEXT LIKE 'SELECT%%'
              AND DIGEST_TEXT NOT LIKE '%%performance_schema%%'
              AND DIGEST_TEXT NOT LIKE '%%information_schema%%'
              AND LAST_SEEN > NOW() - INTERVAL 1 HOUR
              AND QUERY_SAMPLE_TEXT IS NOT NULL""", (self.db, f"%`{self.db}`%"))
        atual, saida = {}, []
        for dig, sample, cnt, soma in rows:
            atual[dig] = (int(cnt), int(soma))
            a = (anterior or {}).get(dig)
            dc, ds = (cnt - a[0], soma - a[1]) if a and cnt > a[0] else (cnt, soma)
            media = round(ds / dc / 1e9, 2) if dc else 0
            if media > LIMITE_MS:
                saida.append({"query_id": dig, "query": sample, "calls": int(cnt), "mean_exec_ms": media})
        saida.sort(key=lambda r: -r["mean_exec_ms"])
        for r in saida[:8]:
            r["plano"], r["pistas"] = self.plano_e_pistas(r["query"])
        return saida[:8], atual

    def _aliases(self, sql):
        m = {}
        for sch, tab, alias in re.findall(r"(?:FROM|JOIN)\s+`?(\w+)`?\.`?(\w+)`?(?:\s+(?:AS\s+)?(?!WHERE|JOIN|ON|LEFT|INNER|GROUP|ORDER|LIMIT)(\w+))?",
                                          sql, re.I):
            m[(alias or tab).lower()] = (sch, tab)
        return m

    def plano_e_pistas(self, sql):
        try:
            plano = self.q("EXPLAIN FORMAT=TREE " + sql)[0][0]
            js = json.loads(self.q("EXPLAIN FORMAT=JSON " + sql)[0][0])
        except Exception as e:  # noqa: BLE001
            return f"Erro no EXPLAIN: {e}", texto_pistas([], [], [])
        aliases = self._aliases(sql)
        tabelas = []

        def andar(n):
            if isinstance(n, dict):
                if "table_name" in n and "access_type" in n:
                    tabelas.append(n)
                for v in n.values():
                    andar(v)
            elif isinstance(n, list):
                for v in n:
                    andar(v)
        andar(js)

        achados, existentes, candidatos = [], [], []
        for t in tabelas:
            if t.get("access_type") != "ALL" or int(t.get("rows_examined_per_scan", 0)) < MIN_LINHAS:
                continue
            alias = t["table_name"].lower()
            sch, tab = aliases.get(alias, (self.db, t["table_name"]))
            cond = t.get("attached_condition", "")
            achados.append(f"- leitura completa (access_type ALL) em {sch}.{tab} (~{t['rows_examined_per_scan']} linhas)"
                           + (f", filtro: {cond}" if cond else ", sem filtro"))
            idx = self.q("""SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS
                            WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s GROUP BY INDEX_NAME""", (sch, tab))
            existentes.append(f"- {sch}.{tab}: " + ", ".join(f"{n} ({c})" for n, c in idx))
            primeiras = {c.split(",")[0].lower() for _, c in idx}
            eq, rng, join = [], [], []
            for pred in re.split(r"\)\s+and\s+\(", cond.strip("()")):
                if re.search(r"\bor\b|<>|!=|\blike\b", pred, re.I):
                    continue
                m = re.match(rf"\(*`\w+`\.`{re.escape(t['table_name'])}`\.`(\w+)`\s*(=|<=|>=|<|>)\s*(.+?)\)*$", pred.strip())
                if not m:
                    continue
                col, op, val = m.group(1), m.group(2), m.group(3)
                if val.startswith("`"):
                    if op == "=":
                        join.append(col)
                elif op == "=":
                    eq.append(col)
                else:
                    rng.append(col)
            cols = list(dict.fromkeys(eq + rng[:1])) or list(dict.fromkeys(join))[:1]
            if cols and cols[0].lower() not in primeiras:
                candidatos.append(f"- CREATE INDEX {nome_indice(tab, cols)} ON {sch}.{tab} ({', '.join(cols)}) ALGORITHM=INPLACE LOCK=NONE;")
        return plano, texto_pistas(achados, existentes, candidatos)

    def saude(self):
        out = []
        for sch, tab, idx in self.q("SELECT object_schema, object_name, index_name FROM sys.schema_unused_indexes WHERE object_schema = %s", (self.db,)):
            out.append(("INDICE_SEM_USO", f"{sch}.{tab}.{idx}", "nenhuma leitura desde que o MySQL subiu", None))
        for sch, tab, red, dom in self.q("""SELECT table_schema, table_name, redundant_index_name, dominant_index_name
                                            FROM sys.schema_redundant_indexes WHERE table_schema = %s""", (self.db,)):
            out.append(("INDICE_DUPLICADO", f"{sch}.{tab}.{red}", f"coberto por {dom}", None))
        for tab, mb in self.q("""SELECT t.TABLE_NAME, ROUND((t.DATA_LENGTH + t.INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES t
                                 WHERE t.TABLE_SCHEMA = %s AND t.TABLE_TYPE = 'BASE TABLE'
                                   AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS k WHERE k.TABLE_SCHEMA = t.TABLE_SCHEMA
                                                   AND k.TABLE_NAME = t.TABLE_NAME AND k.CONSTRAINT_TYPE = 'PRIMARY KEY')""", (self.db,)):
            out.append(("SEM_PK", f"{self.db}.{tab}", "tabela sem chave primária (InnoDB cria uma chave oculta)", float(mb)))
        for tab, linhas, mb in self.q("""SELECT TABLE_NAME, TABLE_ROWS, ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES
                                         WHERE TABLE_SCHEMA = %s AND TABLE_TYPE = 'BASE TABLE' ORDER BY DATA_LENGTH + INDEX_LENGTH DESC LIMIT 5""", (self.db,)):
            out.append(("MAIOR_TABELA", f"{self.db}.{tab}", f"{linhas} linhas", float(mb)))
        return out

    # ---------------- executor
    def aplicar(self, cmds):
        feitos = []
        for cmd in cmds:
            try:
                self.q(cmd)
                feitos.append(cmd)
            except Exception as e:  # noqa: BLE001
                if "1061" in str(e) or "Duplicate key name" in str(e):
                    feitos.append(cmd + "  -- já existia")
                else:
                    raise
            m = re.search(r"\bON\s+([\w.]+)", cmd, re.I)
            if m:
                self.q(f"ANALYZE TABLE {m.group(1)}")
        return feitos

    def _digest(self, dig):
        r = self.q("SELECT COUNT_STAR, SUM_TIMER_WAIT FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST = %s", (dig,))
        return (int(r[0][0]), int(r[0][1])) if r else (0, 0)

    def marco(self, query_id):
        return self._digest(query_id)

    def medir(self, query_id, marco):
        c, s = self._digest(query_id)
        return round((s - marco[1]) / (c - marco[0]) / 1e9, 2) if c > marco[0] else None


# =====================================================================
# SQL Server (DMVs + plano XML com MissingIndexes)
# =====================================================================
NS = "{http://schemas.microsoft.com/sqlserver/2004/07/showplan}"


def pistas_sqlserver(plano_xml: str, existentes_por_tabela=None):
    """Lê o plano XML: leituras completas em tabela grande e os índices que o próprio otimizador pediu."""
    root = ET.fromstring(plano_xml)
    achados, candidatos, resumo, tabelas = [], [], [], set()

    def objeto(relop):
        """Tabela lida pelo próprio operador (sem descer para os operadores filhos)."""
        for op in relop:
            obj = op.find(f"{NS}Object")
            if obj is not None:
                return obj
        return None

    def desc(relop, nivel):
        obj = objeto(relop)
        alvo = f" em {obj.get('Schema')}.{obj.get('Table')}" if obj is not None and obj.get("Table") else ""
        resumo.append(f"{'  ' * nivel}{relop.get('PhysicalOp')}{alvo} (linhas estimadas {relop.get('EstimateRows')})")
        for filho in relop:
            for r in filho.findall(f"{NS}RelOp"):
                desc(r, nivel + 1)

    for qp in root.iter(f"{NS}QueryPlan"):
        for r in qp.findall(f"{NS}RelOp"):
            desc(r, 0)

    for relop in root.iter(f"{NS}RelOp"):
        if relop.get("PhysicalOp") not in ("Table Scan", "Clustered Index Scan", "Index Scan"):
            continue
        lidas = float(relop.get("TableCardinality") or relop.get("EstimatedRowsRead") or 0)
        if lidas < MIN_LINHAS:
            continue
        obj = objeto(relop)
        pred = relop.find(f".//{NS}Predicate/{NS}ScalarOperator")
        tab = f"{obj.get('Schema')}.{obj.get('Table')}" if obj is not None else "?"
        tabelas.add(tab)
        achados.append(f"- {relop.get('PhysicalOp')} em {tab} (~{int(lidas)} linhas)"
                       + (f", filtro: {pred.get('ScalarString')}" if pred is not None else ", sem filtro"))

    for grupo in root.iter(f"{NS}MissingIndexGroup"):
        impacto = float(grupo.get("Impact", 0))
        for mi in grupo.findall(f"{NS}MissingIndex"):
            usos = {"EQUALITY": [], "INEQUALITY": [], "INCLUDE": []}
            for cg in mi.findall(f"{NS}ColumnGroup"):
                usos[cg.get("Usage")] += [c.get("Name") for c in cg.findall(f"{NS}Column")]
            chave = usos["EQUALITY"] + usos["INEQUALITY"]
            if not chave:
                continue
            sch, tab = mi.get("Schema"), mi.get("Table")
            nome = nome_indice(tab.strip("[]"), [c.strip("[]") for c in chave])
            inc = f" INCLUDE ({', '.join(usos['INCLUDE'][:6])})" if usos["INCLUDE"] else ""
            cmd = f"- CREATE INDEX [{nome}] ON {sch}.{tab} ({', '.join(chave)}){inc} WITH (ONLINE = ON);"
            if cmd not in candidatos:
                candidatos.append(cmd)
                achados.append(f"- o otimizador do SQL Server pediu um índice em {sch}.{tab} (impacto estimado {impacto:.0f}%)")

    existentes = [f"- {t}: {existentes_por_tabela[t]}" for t in sorted(tabelas) if existentes_por_tabela and t in existentes_por_tabela]
    return "\n".join(resumo), texto_pistas(achados, existentes, candidatos), sorted(tabelas)


class SQLServer:
    banco = "SQLSERVER"

    def __init__(self, amb, admin=False):
        import pymssql
        self.db = amb["nome_banco"]
        self.c = pymssql.connect(server=amb["host"], port=str(amb["porta"]),
                                 user="sa" if admin else MON_USER, password=SA_PWD if admin else MON_PWD,
                                 database=self.db, login_timeout=5, timeout=300, autocommit=True)

    def close(self):
        self.c.close()

    def q(self, sql, args=None):
        cur = self.c.cursor()
        cur.execute(sql, args)
        try:
            return cur.fetchall()
        except Exception:  # noqa: BLE001 - comando sem resultado
            return []

    def top_lentas(self, anterior=None):
        rows = self.q("""
            WITH q AS (
              SELECT qs.query_hash, qs.execution_count, qs.total_elapsed_time, qs.last_execution_time
              FROM sys.dm_exec_query_stats qs
              CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
              CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
              WHERE pa.attribute = 'dbid' AND CONVERT(int, pa.value) = DB_ID()
                AND st.text NOT LIKE '%%sys.%%' AND st.text NOT LIKE '%%INFORMATION_SCHEMA%%'
                AND LTRIM(st.text) LIKE 'SELECT%%'
            )
            SELECT TOP 8 CONVERT(varchar(20), query_hash, 1), SUM(execution_count),
                   CAST(SUM(total_elapsed_time) / 1000.0 / SUM(execution_count) AS decimal(14,2))
            FROM q
            GROUP BY query_hash
            HAVING SUM(total_elapsed_time) / 1000.0 / SUM(execution_count) > %s
               AND MAX(last_execution_time) > DATEADD(hour, -1, GETDATE())
            ORDER BY 3 DESC""", (LIMITE_MS,))
        saida = []
        for qh, calls, media in rows:
            det = self.q("""
                SELECT TOP 1 SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
                         (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
                          - qs.statement_start_offset) / 2 + 1),
                       tqp.query_plan
                FROM sys.dm_exec_query_stats qs
                CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
                CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset) tqp
                WHERE qs.query_hash = CONVERT(binary(8), %s, 1)
                ORDER BY qs.last_execution_time DESC""", (qh,))
            if not det or not det[0][1]:
                continue
            texto, xml = det[0]
            try:
                _, _, tabs = pistas_sqlserver(xml)
                plano, pistas, _ = pistas_sqlserver(xml, self._indices(tabs))
            except ET.ParseError as e:
                plano, pistas = f"Erro ao ler o plano: {e}", texto_pistas([], [], [])
            saida.append({"query_id": qh, "query": texto.strip(), "calls": int(calls), "mean_exec_ms": float(media),
                          "plano": plano, "pistas": pistas})
        return saida, None

    def _indices(self, tabelas):
        out = {}
        for t in tabelas:
            rows = self.q("""
                SELECT i.name, STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
                FROM sys.indexes i
                JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                WHERE i.object_id = OBJECT_ID(%s) GROUP BY i.name""", (t,))
            out[t] = ", ".join(f"{n} ({c})" for n, c in rows) or "(heap, sem índice)"
        return out

    def saude(self):
        out = []
        for obj, idx, mb in self.q("""
            SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name, i.name, SUM(ps.used_page_count) * 8 / 1024.0
            FROM sys.indexes i
            JOIN sys.objects o ON o.object_id = i.object_id AND o.type = 'U'
            JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
            LEFT JOIN sys.dm_db_index_usage_stats u ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
            WHERE i.type_desc = 'NONCLUSTERED' AND i.is_primary_key = 0 AND i.is_unique = 0
              AND COALESCE(u.user_seeks + u.user_scans + u.user_lookups, 0) = 0
            GROUP BY o.schema_id, o.name, i.name"""):
            out.append(("INDICE_SEM_USO", f"{obj}.{idx}", "nenhuma leitura desde que o SQL Server subiu", float(mb)))
        for obj, a, b in self.q("""
            WITH k AS (
              SELECT i.object_id, i.name, STRING_AGG(CAST(ic.column_id AS varchar(10)), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS cols
              FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
              WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.type > 0
              GROUP BY i.object_id, i.name)
            SELECT OBJECT_SCHEMA_NAME(a.object_id) + '.' + OBJECT_NAME(a.object_id), a.name, b.name
            FROM k a JOIN k b ON a.object_id = b.object_id AND a.cols = b.cols AND a.name > b.name"""):
            out.append(("INDICE_DUPLICADO", f"{obj}.{a}", f"mesmas colunas de {b}", None))
        for obj, mb in self.q("""
            SELECT SCHEMA_NAME(t.schema_id) + '.' + t.name, SUM(ps.used_page_count) * 8 / 1024.0
            FROM sys.tables t JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
            WHERE OBJECTPROPERTY(t.object_id, 'TableHasPrimaryKey') = 0
            GROUP BY t.schema_id, t.name"""):
            out.append(("SEM_PK", obj, "tabela sem chave primária (heap)", float(mb)))
        for obj, linhas, mb in self.q("""
            SELECT TOP 5 SCHEMA_NAME(t.schema_id) + '.' + t.name,
                   SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END), SUM(ps.used_page_count) * 8 / 1024.0
            FROM sys.tables t JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
            GROUP BY t.schema_id, t.name ORDER BY 3 DESC"""):
            out.append(("MAIOR_TABELA", obj, f"{linhas} linhas", float(mb)))
        return out

    def aplicar(self, cmds):
        feitos = []
        for cmd in cmds:
            try:
                self.q(cmd)
                feitos.append(cmd)
            except Exception as e:  # noqa: BLE001
                if "1913" in str(e) or "already exists" in str(e):
                    feitos.append(cmd + "  -- já existia")
                else:
                    raise
            m = re.search(r"\bON\s+(\[?\w+\]?\.\[?\w+\]?)", cmd, re.I)
            if m:
                self.q(f"UPDATE STATISTICS {m.group(1)}")
        return feitos

    def marco(self, query_id):
        return self.q("SELECT SYSDATETIME()")[0][0]

    def medir(self, query_id, marco):
        r = self.q("""SELECT SUM(execution_count), SUM(total_elapsed_time) / 1000.0 / NULLIF(SUM(execution_count), 0)
                      FROM sys.dm_exec_query_stats
                      WHERE query_hash = CONVERT(binary(8), %s, 1) AND creation_time >= %s""", (query_id, marco))
        return round(float(r[0][1]), 2) if r and r[0][0] else None


# =====================================================================
# MongoDB (profiler + planSummary COLLSCAN)
# =====================================================================
FAIXA = {"$gt", "$gte", "$lt", "$lte"}


def forma(v):
    """Formato da consulta sem os valores: agrupa execuções da mesma consulta."""
    if isinstance(v, dict):
        return {k: forma(x) for k, x in sorted(v.items())}
    if isinstance(v, list):
        return [forma(x) for x in v[:1]]
    return 1


def comando_mongo(cmd: dict):
    """Extrai coleção, filtro e ordenação de um find ou aggregate."""
    if "find" in cmd:
        return cmd["find"], cmd.get("filter", {}), cmd.get("sort", {})
    if "aggregate" in cmd:
        pipe = cmd.get("pipeline", [])
        filtro = pipe[0].get("$match", {}) if pipe and "$match" in pipe[0] else {}
        sort = {}
        for etapa in pipe:   # só a ordenação antes de agrupar/projetar usa índice
            if "$sort" in etapa:
                sort = etapa["$sort"]
                break
            if set(etapa) & {"$group", "$project", "$unwind", "$lookup", "$addFields"}:
                break
        return cmd["aggregate"], filtro, sort
    return None, {}, {}


def pistas_mongo(db, coll, filtro, sort, plan_summary, docs_lidos, indices_existentes):
    achados, candidatos = [], []
    if "COLLSCAN" in (plan_summary or "") and docs_lidos >= MIN_LINHAS:
        achados.append(f"- COLLSCAN em {db}.{coll} (~{int(docs_lidos)} documentos lidos por execução), filtro: {json.dumps(forma(filtro))}")
        # Regra ESR: igualdade, depois ordenação, depois faixa
        eq = [k for k, v in filtro.items() if not k.startswith("$") and (not isinstance(v, dict) or set(v) & {"$eq", "$in"})]
        faixa = [k for k, v in filtro.items() if isinstance(v, dict) and set(v) & FAIXA]
        chaves = {k: 1 for k in eq}
        for k, d in sort.items():
            chaves.setdefault(k, d)
        for k in faixa:
            chaves.setdefault(k, 1)
        primeiras = {list(ix["key"])[0][0] for ix in indices_existentes.values()}
        if chaves and next(iter(chaves)) not in primeiras:
            candidatos.append(f"- CREATE INDEX {nome_indice(coll, list(chaves))} ON {db}.{coll} {json.dumps(chaves)};")
    existentes = [f"- {db}.{coll}: " + ", ".join(f"{n} ({', '.join(k for k, _ in ix['key'])})" for n, ix in indices_existentes.items())]
    return texto_pistas(achados, existentes if achados else [], candidatos)


class MongoDB:
    banco = "MONGODB"

    def __init__(self, amb, admin=False):
        from pymongo import MongoClient
        user, pwd = (ADMIN_USER, ADMIN_PWD) if admin else (MON_USER, MON_PWD)
        self.cli = MongoClient(host=amb["host"], port=int(amb["porta"]), username=user, password=pwd,
                               authSource="admin" if admin else amb["nome_banco"], serverSelectionTimeoutMS=5000)
        self.dbname = amb["nome_banco"]
        self.db = self.cli[self.dbname]

    def close(self):
        self.cli.close()

    def _perfil(self, desde, ns_prefixo=True):
        filtro = {"ts": {"$gte": desde}, "op": {"$in": ["query", "command"]},
                  "ns": {"$regex": f"^{self.dbname}\\.(?!system\\.)"},
                  "$or": [{"command.find": {"$exists": True}}, {"command.aggregate": {"$exists": True}}]}
        return self.db["system.profile"].find(filtro, {"command": 1, "millis": 1, "planSummary": 1, "docsExamined": 1, "ns": 1}
                                              ).sort("ts", -1).limit(50000)

    @staticmethod
    def id_da_consulta(ns, cmd):
        coll, filtro, sort = comando_mongo(cmd)
        return hashlib.md5(json.dumps([ns, forma(filtro), forma(sort)], sort_keys=True).encode()).hexdigest()[:16]

    def top_lentas(self, anterior=None):
        grupos = {}
        for d in self._perfil(datetime.now(timezone.utc) - timedelta(minutes=15)):
            cmd = d.get("command", {})
            qid = self.id_da_consulta(d["ns"], cmd)
            g = grupos.setdefault(qid, {"n": 0, "ms": 0, "docs": 0, "ex": d})
            g["n"] += 1
            g["ms"] += d.get("millis", 0)
            g["docs"] += d.get("docsExamined", 0)
        saida = []
        for qid, g in grupos.items():
            media = g["ms"] / g["n"]
            if media <= LIMITE_MS:
                continue
            d = g["ex"]
            coll, filtro, sort = comando_mongo(d["command"])
            cmd_limpo = {k: v for k, v in d["command"].items() if not k.startswith("$") and k not in ("lsid", "cursor")}
            idx = self.db[coll].index_information()
            pistas = pistas_mongo(self.dbname, coll, filtro, sort, d.get("planSummary"), g["docs"] / g["n"],
                                  {n: {"key": v["key"]} for n, v in idx.items()})
            saida.append({"query_id": qid, "query": f"db.{coll}: " + json.dumps(cmd_limpo, default=str, ensure_ascii=False),
                          "calls": g["n"], "mean_exec_ms": round(media, 2),
                          "plano": f"planSummary: {d.get('planSummary')}; documentos lidos por execução: {int(g['docs'] / g['n'])}",
                          "pistas": pistas})
        saida.sort(key=lambda r: -r["mean_exec_ms"])
        return saida[:8], None

    def saude(self):
        out = []
        for nome in self.db.list_collection_names():
            if nome.startswith("system."):
                continue
            st = self.db.command("collStats", nome)
            for ix in self.db[nome].aggregate([{"$indexStats": {}}]):
                if ix["name"] != "_id_" and ix["accesses"]["ops"] == 0:
                    out.append(("INDICE_SEM_USO", f"{self.dbname}.{nome}.{ix['name']}", "nenhuma leitura desde que o MongoDB subiu", None))
            out.append(("MAIOR_TABELA", f"{self.dbname}.{nome}", f"{st['count']} documentos",
                        round((st["size"] + st["totalIndexSize"]) / 1048576, 1)))
        maiores = sorted([o for o in out if o[0] == "MAIOR_TABELA"], key=lambda o: -o[3])[:5]
        return [o for o in out if o[0] != "MAIOR_TABELA"] + maiores

    def garantir_profiler(self):
        if self.db.command("profile", -1).get("was") != 2:
            self.db.command("profile", 2)

    def aplicar(self, cmds):
        feitos = []
        for cmd in cmds:
            m = re.match(r"CREATE INDEX (\w+) ON (\w+)\.(\w+) (\{.*\})", cmd)
            if not m:
                raise ValueError(f"comando não reconhecido: {cmd}")
            nome, _, coll, chaves = m.groups()
            self.db[coll].create_index(list(json.loads(chaves).items()), name=nome)
            feitos.append(f'db.{coll}.createIndex({chaves}, {{name: "{nome}"}})')
        return feitos

    def marco(self, query_id):
        self.garantir_profiler()
        return datetime.now(timezone.utc)

    def medir(self, query_id, marco):
        ms = [d.get("millis", 0) for d in self._perfil(marco) if self.id_da_consulta(d["ns"], d.get("command", {})) == query_id]
        return round(sum(ms) / len(ms), 2) if ms else None


CONECTORES = {"MYSQL": MySQL, "SQLSERVER": SQLServer, "MONGODB": MongoDB}
