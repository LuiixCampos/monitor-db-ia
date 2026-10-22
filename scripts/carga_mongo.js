// Simula o app no MongoDB: histórico de navegação, avaliações do produto,
// lista de desejos e termos mais buscados. Liga o profiler (nível 2) para o monitor.
const app = db.getSiblingDB("app");
while (app.listas_desejo.estimatedDocumentCount() === 0) sleep(15000);
app.setProfilingLevel(2);
print("Iniciando carga do app (MongoDB)...");
const rnd = (n) => Math.floor(Math.random() * n);
const sku = (n) => "SKU" + String(n).padStart(6, "0");
while (true) {
  const cli = 1 + rnd(300000);
  try {
    // "Vistos recentemente" do cliente
    app.eventos_navegacao.find({ cliente_id: cli }).sort({ ts: -1 }).limit(20).toArray();
    // Avaliações aprovadas do produto
    app.avaliacoes.find({ sku: sku(1 + rnd(20000)), aprovada: true }).sort({ ts: -1 }).limit(10).toArray();
    // Lista de desejos do cliente
    app.listas_desejo.find({ cliente_id: cli }).toArray();
    // Termos mais buscados na última hora
    app.eventos_navegacao.aggregate([
      { $match: { tipo: "SEARCH", ts: { $gte: new Date(Date.now() - 3600000) } } },
      { $group: { _id: "$termo", n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 10 }]).toArray();
  } catch (e) { print("erro na carga: " + e); }
  sleep(10000);
}
