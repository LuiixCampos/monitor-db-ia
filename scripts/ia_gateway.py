"""
Gateway de IA do monitor-db-ia.

Fala o mesmo "idioma" do Ollama (POST /api/generate), então os fluxos do
n8n não mudam quando a IA muda. O provedor é escolhido no .env:

  IA_PROVEDOR=ollama        IA local e gratuita (padrão; nada sai da máquina)
  IA_PROVEDOR=claude        API da Anthropic (ANTHROPIC_API_KEY, CLAUDE_MODELO)
  IA_PROVEDOR=azure_openai  Azure OpenAI (AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_KEY, AZURE_OPENAI_DEPLOYMENT)

Com IA_FALLBACK_OLLAMA=1, se o provedor de nuvem falhar a análise sai pelo Ollama.
Só usa a biblioteca padrão do Python.
"""
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROVEDOR = os.environ.get("IA_PROVEDOR", "ollama").strip().lower()
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
OLLAMA_MODELO = os.environ.get("OLLAMA_MODELO", "qwen2.5:3b")
CLAUDE_MODELO = os.environ.get("CLAUDE_MODELO", "claude-sonnet-5-5")
FALLBACK = os.environ.get("IA_FALLBACK_OLLAMA", "0") == "1"
TIMEOUT = int(os.environ.get("IA_TIMEOUT_SEG", "600"))


def post(url, corpo, cabecalhos):
    req = urllib.request.Request(url, data=json.dumps(corpo).encode(), method="POST",
                                 headers={"content-type": "application/json", **cabecalhos})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read())


def ollama(prompt, opcoes, modelo=None):
    r = post(f"{OLLAMA_URL}/api/generate",
             {"model": modelo or OLLAMA_MODELO, "prompt": prompt, "stream": False, "options": opcoes}, {})
    return r["response"], r.get("model", modelo or OLLAMA_MODELO)


def claude(prompt, opcoes):
    r = post("https://api.anthropic.com/v1/messages",
             {"model": CLAUDE_MODELO, "max_tokens": max(int(opcoes.get("num_predict", 800)), 800),
              "temperature": float(opcoes.get("temperature", 0.1)),
              "messages": [{"role": "user", "content": prompt}]},
             {"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01"})
    return "".join(b.get("text", "") for b in r["content"]), r.get("model", CLAUDE_MODELO)


def azure_openai(prompt, opcoes):
    base = os.environ["AZURE_OPENAI_ENDPOINT"].rstrip("/")
    dep = os.environ["AZURE_OPENAI_DEPLOYMENT"]
    versao = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21")
    r = post(f"{base}/openai/deployments/{dep}/chat/completions?api-version={versao}",
             {"messages": [{"role": "user", "content": prompt}],
              "temperature": float(opcoes.get("temperature", 0.1)),
              "max_tokens": max(int(opcoes.get("num_predict", 800)), 800)},
             {"api-key": os.environ["AZURE_OPENAI_KEY"]})
    return r["choices"][0]["message"]["content"], f"azure:{dep}"


PROVEDORES = {"ollama": ollama, "claude": claude, "azure_openai": azure_openai}


def gerar(corpo):
    prompt, opcoes = corpo.get("prompt", ""), corpo.get("options") or {}
    if PROVEDOR == "ollama":
        return ollama(prompt, opcoes, corpo.get("model"))
    try:
        return PROVEDORES[PROVEDOR](prompt, opcoes)
    except Exception as e:  # noqa: BLE001
        if not FALLBACK:
            raise
        print(f"{PROVEDOR} falhou ({e}); usando o Ollama", flush=True)
        return ollama(prompt, opcoes, corpo.get("model"))


class Handler(BaseHTTPRequestHandler):
    def responder(self, codigo, obj):
        out = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        self.responder(200, {"provedor": PROVEDOR, "modelo": CLAUDE_MODELO if PROVEDOR == "claude" else
                             os.environ.get("AZURE_OPENAI_DEPLOYMENT") if PROVEDOR == "azure_openai" else OLLAMA_MODELO})

    def do_POST(self):
        if self.path != "/api/generate":
            self.send_error(404)
            return
        corpo = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        try:
            texto, modelo = gerar(corpo)
            self.responder(200, {"model": modelo, "response": texto, "done": True})
        except Exception as e:  # noqa: BLE001
            print(f"erro: {e}", flush=True)
            self.responder(502, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if PROVEDOR not in PROVEDORES:
        raise SystemExit(f"IA_PROVEDOR inválido: {PROVEDOR} (use ollama, claude ou azure_openai)")
    print(f"gateway de IA na porta 8080, provedor: {PROVEDOR}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
