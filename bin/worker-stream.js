#!/usr/bin/env node
// Usage: claude -p ... --output-format stream-json --verbose | node worker-stream.js <activity file>
// Reads the worker's JSON stream. Every tool use is appended to the activity file as a line
// "<seconds since 1970>\t<tool>\t<target>", so qwen-progress.sh can report during a stage
// what the worker is currently working on.
// stdout only gets what the caller would get without the transcript: the final report
// and anything that is not JSON (error messages, notices).
const fs = require("fs");
const readline = require("readline");

const activityFile = process.argv[2];
let lastText = "";
let finished = false;

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
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    if (line.trim()) console.log(line);
    return;
  }
  if (!event || typeof event !== "object") {
    console.log(line);
    return;
  }
  if (event.type === "assistant" && event.message && Array.isArray(event.message.content)) {
    for (const block of event.message.content) {
      if (block.type === "text" && block.text && block.text.trim()) lastText = block.text;
      if (block.type === "tool_use") {
        const input = block.input || {};
        note(block.name, input.file_path || input.path || input.command || input.pattern || "");
      }
    }
  } else if (event.type === "result") {
    finished = true;
    const text = typeof event.result === "string" && event.result.trim() ? event.result : lastText;
    if (text) console.log(text);
    // Without the transcript, claude -p prints these notices itself; in the JSON stream they are
    // only in the result event. qwen-first.sh needs "Reached max turns" to start a continuation
    // on what has been changed so far instead of a new attempt from scratch.
    const subtype = String(event.subtype || "");
    if (subtype.includes("max_turns")) {
      console.log(`Reached max turns (${event.num_turns ?? "?"})`);
    } else if (event.is_error || subtype.startsWith("error")) {
      console.log(`WORKER-ERROR: ${subtype || "is_error"}`);
    }
  }
});
rl.on("close", () => {
  // No result event (aborted by time limit): at least pass on the last text.
  if (!finished && lastText) console.log(lastText);
});
