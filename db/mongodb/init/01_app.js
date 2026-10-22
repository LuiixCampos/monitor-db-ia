// =====================================================================
// Catálogo, avaliações, listas de desejo e navegação do app (MongoDB)
// Base FICTÍCIA. Só o índice _id, de propósito. ~2,7 milhões de documentos.
// Roda uma vez, na primeira subida do container (docker-entrypoint-initdb.d).
// =====================================================================
const app = db.getSiblingDB("app");
const rnd = (n) => Math.floor(Math.random() * n);
const pick = (a) => a[rnd(a.length)];
const agora = Date.now();
const DIA = 86400000;

function lote(colecao, total, gerar) {
  const L = 10000;
  for (let i = 0; i < total; i += L) {
    const docs = [];
    for (let j = i; j < Math.min(i + L, total); j++) docs.push(gerar(j + 1));
    app[colecao].insertMany(docs, { ordered: false });
  }
  print(`${colecao}: ${total} documentos`);
}

const cats = ["Blusa", "Vestido", "Saia", "Camisa", "Bermuda", "Calca", "Conjunto", "Pijama", "Tenis", "Sandalia", "Bolsa", "Toalha"];
const deps = ["FEMININO", "FEMININO", "FEMININO", "MASCULINO", "MASCULINO", "MASCULINO", "INFANTIL", "INFANTIL", "CALCADOS", "CALCADOS", "ACESSORIOS", "CASA"];
const sku = (n) => "SKU" + String(n).padStart(6, "0");

lote("produtos", 20000, (n) => ({
  sku: sku(n), titulo: `${cats[n % 12]} modelo ${n}`, departamento: deps[n % 12],
  preco: Math.round((29.9 + Math.random() * 470) * 100) / 100,
  cores: ["Preto", "Branco", "Azul", "Rosa"].slice(0, 1 + rnd(4)),
  tamanhos: ["P", "M", "G", "GG"].slice(0, 2 + rnd(3)),
  ativo: Math.random() > 0.08, atualizado_em: new Date(agora - rnd(60) * DIA)
}));

lote("eventos_navegacao", 2000000, (n) => {
  const tipo = pick(["VIEW", "VIEW", "VIEW", "VIEW", "SEARCH", "ADD_CART", "CHECKOUT"]);
  return {
    cliente_id: 1 + rnd(300000), sessao: "s" + Math.floor(n / 6), tipo,
    sku: tipo === "SEARCH" ? null : sku(1 + rnd(20000)),
    termo: tipo === "SEARCH" ? pick(["vestido", "tenis", "jeans", "pijama", "bolsa", "camisa social", "biquini"]) : null,
    device: pick(["ANDROID", "ANDROID", "IOS", "WEB"]), ts: new Date(agora - rnd(30 * DIA))
  };
});

lote("avaliacoes", 300000, () => ({
  sku: sku(1 + rnd(20000)), cliente_id: 1 + rnd(300000), nota: 1 + rnd(5),
  comentario: pick(["Gostei", "Veste bem", "Tecido fino", "Chegou rapido", "Tamanho pequeno", "Recomendo"]),
  aprovada: Math.random() > 0.1, ts: new Date(agora - rnd(365 * DIA))
}));

lote("listas_desejo", 400000, () => ({
  cliente_id: 1 + rnd(300000), sku: sku(1 + rnd(20000)), ts: new Date(agora - rnd(180 * DIA))
}));

// Índice que ninguém usa, de propósito (o monitor deve achar)
app.produtos.createIndex({ preco: 1 }, { name: "idx_produtos_preco" });

// Profiler com espaço para medir antes x depois (a carga liga o nível 2)
app.setProfilingLevel(0);
app.getCollection("system.profile").drop();
app.createCollection("system.profile", { capped: true, size: 64 * 1024 * 1024 });

// Usuário de monitoramento: lê os dados, o profiler e as estatísticas
app.createRole({
  role: "leituraProfiler",
  privileges: [{ resource: { db: "app", collection: "system.profile" }, actions: ["find"] },
               { resource: { db: "app", collection: "" }, actions: ["collStats", "indexStats", "listIndexes", "listCollections"] }],
  roles: []
});
app.createUser({
  user: "monitor_user", pwd: process.env.MONITOR_PASSWORD,
  roles: [{ role: "read", db: "app" }, { role: "leituraProfiler", db: "app" }, { role: "clusterMonitor", db: "admin" }]
});
print("Base do app criada.");
