// Usage: claude -p ... --output-format json | node usage-log.js <name>
//        node usage-log.js --sum
const fs = require("fs");
const LOG = ".worker/usage.log";
if (process.argv[2] === "--sum") {
  const rows = fs.existsSync(LOG) ? fs.readFileSync(LOG, "utf8").trim().split("\n").filter(Boolean).map(l => JSON.parse(l)) : [];
  const t = { input: 0, cache_write: 0, cache_read: 0, output: 0, cost: 0 };
  for (const r of rows) {
    console.log(`${r.name}: turns ${r.iter ?? "?"}, input ${r.input}, cache written ${r.cache_write}, cache read ${r.cache_read}, output ${r.output}, cost ${r.cost.toFixed(4)} USD`);
    for (const k in t) t[k] += r[k];
  }
  console.log(`SUM ${rows.length} calls: input ${t.input}, cache written ${t.cache_write}, cache read ${t.cache_read}, output ${t.output}, cost ${t.cost.toFixed(4)} USD`);
} else {
  let s = "";
  process.stdin.on("data", d => (s += d)).on("end", () => {
    let j;
    try { j = JSON.parse(s); } catch (e) { process.stdout.write(s); return; }
    const u = j.usage || {};
    fs.mkdirSync(".worker", { recursive: true });
    fs.appendFileSync(LOG, JSON.stringify({
      name: process.argv[2] || "?",
      input: u.input_tokens || 0,
      cache_write: u.cache_creation_input_tokens || 0,
      cache_read: u.cache_read_input_tokens || 0,
      output: u.output_tokens || 0,
      cost: j.total_cost_usd || 0,
      iter: (u.iterations || []).length || 1,
    }) + "\n");
    process.stdout.write((j.result || "") + "\n");
  });
}
