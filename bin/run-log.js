#!/usr/bin/env node
// Metrics log of the Qwen runs: one JSON line per run in ~/.claude/qwen-runs.jsonl.
//   node run-log.js add key=value ...   appends a run (qwen-first.sh calls this at the end)
//   node run-log.js show [N]            shows the last N runs as a table (default 15)
//   node run-log.js cost                sum of the costs in .worker/usage.log (for qwen-first.sh)
// Times come in as seconds (t_<stage>=..., total=...) and are shown in minutes.
const fs = require("fs");
const os = require("os");
const path = require("path");
const FILE = process.env.QWEN_RUNS || path.join(os.homedir(), ".claude", "qwen-runs.jsonl");
const cmd = process.argv[2];

if (cmd === "cost") {
  let sum = 0;
  try {
    for (const line of fs.readFileSync(".worker/usage.log", "utf8").split("\n")) {
      if (line.trim()) sum += JSON.parse(line).cost || 0;
    }
  } catch {
    // no cost log: 0
  }
  console.log(sum.toFixed(4));
} else if (cmd === "add") {
  const row = {};
  for (const arg of process.argv.slice(3)) {
    const i = arg.indexOf("=");
    if (i < 1) continue;
    const key = arg.slice(0, i);
    const val = arg.slice(i + 1).replace(/\s+/g, " ").trim();
    row[key] = val !== "" && /^-?\d+(\.\d+)?$/.test(val) && key !== "task" ? Number(val) : val;
  }
  if (typeof row.task === "string") row.task = row.task.slice(0, 200);
  fs.appendFileSync(FILE, JSON.stringify(row) + "\n");
} else if (cmd === "show") {
  const n = Number(process.argv[3]) || 15;
  let rows = [];
  try {
    rows = fs.readFileSync(FILE, "utf8").split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
  } catch {
    // no log yet
  }
  // Runs logged by the earlier German version use German stage names and results
  const KEY_ALIAS = {
    t_kontext: "t_context", t_basis: "t_baseline", t_schritte: "t_steps", t_pruefung: "t_checks",
    t_abschluss: "t_final", t_selbstkontrolle: "t_selfreview", t_nachpruefung: "t_recheck",
    t_zwischenpruefung: "t_midcheck",
  };
  const RESULT_ALIAS = { gruen: "green", rot: "red", abbruch: "aborted", fertig: "done", zeitlimit: "timeout", "kein-server": "no-server" };
  rows = rows.map((r) => {
    const o = {};
    for (const [k, v] of Object.entries(r)) o[KEY_ALIAS[k] || k] = v;
    if (RESULT_ALIAS[o.result]) o.result = RESULT_ALIAS[o.result];
    return o;
  });
  if (rows.length === 0) {
    console.log("No runs logged yet (" + FILE + ").");
    process.exit(0);
  }
  const min = (s) => (s === undefined || s === "" ? "-" : String(Math.round(Number(s) / 60)));
  // Columns: header, value per run. Stage times in minutes.
  const cols = [
    ["Date", (r) => String(r.date || "").slice(5, 16)],
    ["Project", (r) => String(r.project || "").slice(0, 18)],
    ["Result", (r) => r.result || "?"],
    ["Total", (r) => min(r.total)],
    ["Ctx", (r) => min(r.t_context)],
    ["Plan", (r) => min((r.t_plan || 0) + (r.t_baseline || 0))],
    ["Test", (r) => min(r.t_tests)],
    ["Steps", (r) => min(r.t_steps)],
    ["Check", (r) => min((r.t_checks || 0) + (r.t_final || 0))],
    ["Self", (r) => min(r.t_selfreview)],
    ["Rev", (r) => min(r.t_review)],
    ["RevFix", (r) => min((r.t_reviewfix || 0) + (r.t_recheck || 0))],
    ["Limit", (r) => String(r.timeouts ?? "-")],
    ["Fixes", (r) => String(r.fixes ?? "-")],
    // "2+3": 2 points fixed, 3 out of scope and only noted
    ["Pts", (r) => String(r.review_points ?? "-") + (r.out_of_scope > 0 ? "+" + r.out_of_scope : "")],
    ["Lines", (r) => String(r.lines ?? "-")],
    ["USD", (r) => (typeof r.cost === "number" ? r.cost.toFixed(2) : "-")],
    ["Kind", (r) => (r.kind === "q" ? "/q Qwen only" : String(r.no_tests) === "1" ? "no tests" : "tests " + (r.test_model || "?"))],
    ["Task", (r) => String(r.task || "").slice(0, 44)],
  ];
  const shown = rows.slice(-n);
  const table = [cols.map((c) => c[0]), ...shown.map((r) => cols.map((c) => c[1](r)))];
  const width = cols.map((_, i) => Math.max(...table.map((row) => row[i].length)));
  for (const row of table) console.log(row.map((cell, i) => cell.padEnd(width[i])).join("  ").trimEnd());
  console.log("\nTimes in minutes. Limit = worker time limits, Fixes = fix attempts on red");
  console.log("checks, Pts = points in the final review (+N = out of scope, only noted),");
  console.log("Lines = changed lines in the diff. /q runs only have total time, result and lines.");
  console.log(rows.length + " runs in " + FILE);
} else {
  console.log("Usage: node run-log.js add key=value ... | show [N] | cost");
  process.exit(1);
}
