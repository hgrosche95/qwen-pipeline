#!/usr/bin/env node
// Usage: opencode run --format json ... | node opencode-stream.js <activity file> <step limit>
// The OpenCode counterpart of worker-stream.js: reads OpenCode's JSON events, appends every
// tool use as "<seconds since 1970>\t<tool>\t<target>" to the activity file (same format and
// tool names as with Claude Code, so qwen-progress.sh works unchanged) and prints only the
// final report. If the session used up its step limit without finishing, it prints
// "Reached max turns (N)", so qwen-first.sh continues in a fresh session just like with
// Claude Code. Token usage of the session goes to stderr as one line for the benchmark.
const fs = require("fs");
const readline = require("readline");

const activityFile = process.argv[2];
const stepLimit = Number(process.argv[3]) || 0;
const TOOL = { write: "Write", edit: "Edit", multiedit: "MultiEdit", read: "Read", bash: "Bash", grep: "Grep", glob: "Glob", list: "Glob", patch: "Edit" };
let lastText = "";
let steps = 0;
let lastReason = "";
let tokens = 0;
let errored = "";

function note(tool, target) {
  if (!activityFile) return;
  const clean = String(target || "").replace(/\s+/g, " ").slice(0, 160);
  try {
    fs.appendFileSync(activityFile, `${Math.floor(Date.now() / 1000)}\t${tool}\t${clean}\n`);
  } catch {
    // The transcript is a side feature: a write error must not disturb the worker.
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  let e;
  try {
    e = JSON.parse(line);
  } catch {
    if (line.trim()) console.log(line);
    return;
  }
  const p = (e && e.part) || {};
  if (e.type === "step_start") steps += 1;
  else if (e.type === "tool_use" && p.tool) {
    const input = (p.state && p.state.input) || {};
    const name = TOOL[String(p.tool).toLowerCase()] || p.tool;
    note(name, input.filePath || input.path || input.command || input.pattern || "");
  } else if (e.type === "text" && p.text && p.text.trim()) {
    lastText = p.text;
  } else if (e.type === "step_finish") {
    lastReason = p.reason || "";
    if (p.tokens && p.tokens.total) tokens = Math.max(tokens, p.tokens.total);
  } else if (e.type === "error") {
    errored = JSON.stringify(e.error || p || e).slice(0, 300);
  }
});
rl.on("close", () => {
  if (lastText) console.log(lastText);
  if (errored) console.log(`WORKER-ERROR: ${errored}`);
  else if (stepLimit && steps >= stepLimit && lastReason !== "stop") console.log(`Reached max turns (${steps})`);
  process.stderr.write(`[opencode] steps=${steps} context_tokens=${tokens} finish=${lastReason || "-"}\n`);
});
