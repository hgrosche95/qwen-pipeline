#!/usr/bin/env node
// Usage: pi -p --mode json ... | node pi-stream.js <activity file> <turn limit>
// The Pi counterpart of worker-stream.js: reads Pi's JSONL events, appends every tool use as
// "<seconds since 1970>\t<tool>\t<target>" to the activity file (same format and tool names as
// with Claude Code, so qwen-progress.sh works unchanged) and prints only the final report.
// Pi has no turn limit of its own: when the session goes past <turn limit> turns, this script
// prints "Reached max turns (N)" and exits, which ends Pi on its next write, so qwen-first.sh
// continues in a fresh session just like with Claude Code. Turns and context size of the session
// go to stderr as one line for the benchmark.
// Pi's stream may contain U+2028/U+2029 inside JSON strings, so it is split on LF only
// (readline would also split there).
const fs = require("fs");

const activityFile = process.argv[2];
const turnLimit = Number(process.argv[3]) || 0;
const TOOL = { write: "Write", edit: "Edit", read: "Read", bash: "Bash", grep: "Grep", find: "Glob", ls: "Glob" };
let lastText = "";
let turns = 0;
let context = 0;
let lastStop = "";
let errored = "";
let done = false;
let buf = "";

function note(tool, target) {
  if (!activityFile) return;
  const clean = String(target || "").replace(/\s+/g, " ").slice(0, 160);
  try {
    fs.appendFileSync(activityFile, `${Math.floor(Date.now() / 1000)}\t${tool}\t${clean}\n`);
  } catch {
    // The transcript is a side feature: a write error must not disturb the worker.
  }
}

function report() {
  if (done) return;
  done = true;
  if (lastText) console.log(lastText);
  if (errored) console.log(`WORKER-ERROR: ${errored}`);
  else if (turnLimit && turns > turnLimit) console.log(`Reached max turns (${turnLimit})`);
  process.stderr.write(`[pi] steps=${turns} context_tokens=${context} finish=${lastStop || "-"}\n`);
}

function handle(line) {
  if (!line.trim()) return;
  let e;
  try {
    e = JSON.parse(line);
  } catch {
    console.log(line);
    return;
  }
  if (e.type === "turn_start") {
    turns += 1;
    if (turnLimit && turns > turnLimit) {
      report();
      process.exit(0);
    }
  } else if (e.type === "tool_execution_start") {
    const a = e.args || {};
    note(TOOL[String(e.toolName).toLowerCase()] || e.toolName, a.path || a.file_path || a.command || a.pattern || "");
  } else if (e.type === "message_end" && e.message && e.message.role === "assistant") {
    const m = e.message;
    for (const b of m.content || []) if (b.type === "text" && b.text && b.text.trim()) lastText = b.text;
    if (m.usage) context = Math.max(context, (m.usage.input || 0) + (m.usage.cacheRead || 0) + (m.usage.output || 0));
    lastStop = m.stopReason || lastStop;
    if (m.stopReason === "error" || m.errorMessage) errored = String(m.errorMessage || "provider error").slice(0, 300);
    else errored = "";
  }
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    handle(buf.slice(0, i).replace(/\r$/, ""));
    buf = buf.slice(i + 1);
  }
});
process.stdin.on("end", () => {
  handle(buf);
  report();
});
