#!/usr/bin/env bash
# Usage in the project folder: qwen-bench.sh <task file> [harnesses] [repeats]
#   e.g. qwen-bench.sh .worker/bench-tasks.txt "claude opencode" 2
# Compares worker harnesses fairly: for each task, plan and tests are written ONCE (Opus/Sonnet,
# the only paid part), then every harness implements that same plan against the same tests
# from the same commit. Review is skipped (BENCH_REVIEW=1 turns a Sonnet review back on).
# Runs alternate between harnesses, so time-of-day effects on the model server even out.
# Nothing is merged; every run leaves its own qwen/* branch (listed at the end).
# Results: one row per run in ~/.claude/qwen-runs.jsonl (bench=<id>/...), a summary in
# .worker/bench/<id>/summary.txt and the full log of every run next to it.
set -uo pipefail
FILE="${1:?Usage: qwen-bench.sh <task file> [harnesses] [repeats]}"
HARNESSES="${2:-claude opencode}"
REPEATS="${3:-2}"
FIRST="${QWEN_FIRST:-$HOME/.claude/bin/qwen-first.sh}"
[ -s "$FILE" ] || { echo "ABORT: The task file $FILE is missing or empty."; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ABORT: Not a git project."; exit 1; }
mapfile -t TASKS < <(tr -d '\r' < "$FILE" | grep -vE '^[[:space:]]*(#|$)')
N=${#TASKS[@]}
START=$(git rev-parse --abbrev-ref HEAD)
ID="bench-$(date +%m%d-%H%M)"
DIR=".worker/bench/$ID"; mkdir -p "$DIR"
: > "$DIR/branches.txt"
echo "== Benchmark $ID: $N task(s) x harnesses ($HARNESSES) x $REPEATS repeat(s), starting from $START"

for k in "${!TASKS[@]}"; do
  task="${TASKS[$k]}"; t=$((k+1)); title=$(printf '%s' "$task" | cut -c1-70)
  echo "== Task $t/$N: $title"
  git checkout -q "$START" || { echo "ABORT: cannot switch back to $START"; exit 1; }
  # 1) Plan and tests once
  STOP_AFTER_TESTS=1 PREPARE_OUT="$DIR/t$t" BENCH_ID="$ID/t$t/prepare" \
    bash "$FIRST" "$task" > "$DIR/t$t-prepare.log" 2>&1
  prep=$(sed -n 's/^== Prepared on branch \([^ ]*\).*/\1/p' "$DIR/t$t-prepare.log" | tail -1)
  if [ -z "$prep" ]; then
    echo "   Preparation failed, task skipped: $(grep -m1 -E '^ABORT|^Plan does not' "$DIR/t$t-prepare.log")"
    continue
  fi
  echo "$prep" >> "$DIR/branches.txt"
  echo "   Prepared: $prep ($(grep -c '^## Step ' "$DIR/t$t/plan.md") steps)"
  # 2) Each harness implements the same prepared state, alternating
  for r in $(seq 1 "$REPEATS"); do
    for h in $HARNESSES; do
      git checkout -q "$prep" || continue
      log="$DIR/t$t-$h-$r.log"; t0=$(date +%s)
      ALLOW_ANY_BRANCH=1 PREPARED_DIR="$DIR/t$t" SKIP_REVIEW=$([ "${BENCH_REVIEW:-0}" = "1" ] && echo 0 || echo 1) \
        REVIEW_MODEL="${REVIEW_MODEL:-sonnet}" WORKER_HARNESS="$h" BENCH_ID="$ID/t$t/$h/$r" \
        bash "$FIRST" "$task" > "$log" 2>&1
      br=$(sed -n 's/^== Done on branch //p' "$log" | tail -1)
      [ -z "$br" ] && br=$(git rev-parse --abbrev-ref HEAD | grep '^qwen/')
      [ -n "$br" ] && echo "$br" >> "$DIR/branches.txt"
      cat .worker/*.harness.txt > "$DIR/t$t-$h-$r.harness.txt" 2>/dev/null; rm -f .worker/*.harness.txt
      if grep -q '^Test command green' "$log" && ! grep -q '^WARNING' "$log"; then res=green
      elif grep -q '^ABORT' "$log"; then res=aborted; else res=red; fi
      echo "   $h run $r: $res, $(( ($(date +%s) - t0 + 30) / 60 )) min${br:+, $br}"
    done
  done
done
git checkout -q "$START"

# 3) Summary from the run log
QWEN_RUNS_FILE="${QWEN_RUNS:-$HOME/.claude/qwen-runs.jsonl}"
command -v cygpath >/dev/null 2>&1 && QWEN_RUNS_FILE=$(cygpath -m "$QWEN_RUNS_FILE")
node -e '
const [file, id, dir] = process.argv.slice(1);
const fs = require("fs");
const rows = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
  .filter((r) => r && String(r.bench || "").startsWith(id + "/") && !String(r.bench).endsWith("/prepare"));
const by = {};
for (const r of rows) (by[r.harness || "claude"] ||= []).push(r);
const avg = (a, f) => a.length ? a.reduce((s, r) => s + (Number(f(r)) || 0), 0) / a.length : 0;
const ctx = (h) => { let n = 0, s = 0; for (const f of fs.readdirSync(dir)) if (f.includes("-" + h + "-") && f.endsWith(".harness.txt"))
  for (const m of fs.readFileSync(dir + "/" + f, "utf8").matchAll(/context_tokens=(\d+)/g)) { s += +m[1]; n++; } return n ? Math.round(s / n) : null; };
const out = ["Harness    Runs  Green  Avg min  Steps min  Limits  Fixes  Lines  Avg context"];
for (const [h, a] of Object.entries(by)) {
  const c = ctx(h);
  out.push([h.padEnd(10), String(a.length).padEnd(5), (a.filter((r) => r.result === "green").length + "/" + a.length).padEnd(6),
    (avg(a, (r) => r.total) / 60).toFixed(0).padEnd(8), (avg(a, (r) => r.t_steps) / 60).toFixed(0).padEnd(10),
    avg(a, (r) => r.timeouts).toFixed(1).padEnd(7), avg(a, (r) => r.fixes).toFixed(1).padEnd(6),
    avg(a, (r) => r.lines).toFixed(0).padEnd(6), c ? c + " tokens" : "-"].join(" "));
}
out.push("", "Per task and harness: green runs / runs");
const tasks = [...new Set(rows.map((r) => String(r.bench).split("/")[1]))];
for (const t of tasks) out.push(t + ": " + Object.keys(by).map((h) => { const a = rows.filter((r) => String(r.bench).split("/")[1] === t && (r.harness || "claude") === h);
  return h + " " + a.filter((r) => r.result === "green").length + "/" + a.length; }).join(", "));
out.push("", "Limits = worker time/turn limits per run, Fixes = fix attempts on red checks, Lines = changed lines.");
out.push("Avg context = context size of an OpenCode session (Claude Code does not report it).");
fs.writeFileSync(dir + "/summary.txt", out.join("\n") + "\n");
console.log(out.join("\n"));
' "$QWEN_RUNS_FILE" "$ID" "$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$DIR" || echo "$DIR")"
echo
echo "== Benchmark done: $DIR/summary.txt"
echo "   Branches of this benchmark: $DIR/branches.txt"
echo "   Delete them later: git branch -D \$(cat $DIR/branches.txt)"
