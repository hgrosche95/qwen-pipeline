#!/usr/bin/env bash
# Usage: local-worker.sh <read|code> <task file>
# Runs Claude Code headless against the local model server (Strata) as a "worker".
set -uo pipefail
MODE="$1"; TASK="$2"

# Recursion lock: a worker must not start another worker
if [ -n "${LOCAL_WORKER_ACTIVE:-}" ]; then
  echo "WORKER-RECURSION blocked: You are the worker yourself, do the task directly." >&2
  exit 3
fi
export LOCAL_WORKER_ACTIVE=1

# Address, key and model name of the local server are in ~/.claude/strata.env
# (lines STRATA_URL=..., STRATA_KEY=..., STRATA_MODEL=...). If the file or a value is missing,
# the server from the terminal is used: port 8080 without a real key.
CFG="$HOME/.claude/strata.env"
cfg() { [ -f "$CFG" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" | tr -d '\r' | sed 's/[[:space:]]*$//; s/^"\(.*\)"$/\1/' | tail -1; }
URL="$(cfg STRATA_URL)"; URL="${URL:-http://127.0.0.1:8080}"; URL="${URL%/}"; URL="${URL%/v1}"
KEY="$(cfg STRATA_KEY)"; KEY="${KEY:-strata-local}"
MODEL="$(cfg STRATA_MODEL)"; MODEL="${MODEL:-qwen3.8-flash-next-iq3_xxs}"
LOG="${TASK%.md}.log"

# Pre-check: reachable and key correct? Otherwise the worker only fails after minutes with a
# message that looks like a model error.
CODE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "x-api-key: $KEY" -H "Authorization: Bearer $KEY" "$URL/v1/models" 2>/dev/null)
case "$CODE" in
  000) echo "API Error: Connection error - no Strata server is answering at $URL (check the address in $CFG, load the model)"; exit 4 ;;
  401|403) echo "API Error: The key for $URL is missing or wrong (STRATA_KEY in $CFG)"; exit 4 ;;
esac

export ANTHROPIC_BASE_URL="$URL"
export ANTHROPIC_AUTH_TOKEN="$KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384
export CLAUDE_CONFIG_DIR="$HOME/.claude-worker"
# No auto memory for the worker: it used to write notes per project (13 files after a few
# days) that every later session loaded - stale plan states, and a recipe for starting E2E
# tests with server and database, which made it start servers and read server/.env.
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1

export CLAUDE_CODE_EFFORT_LEVEL="${WORKER_EFFORT:-low}"
export API_FORCE_IDLE_TIMEOUT=0
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000
export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=1800000
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_CODE_MAX_RETRIES=2

# Hard limit per shell command of the worker. The prompt forbids servers and wait loops, but
# the worker once ignored that and hung in a Docker wait loop until the stage time limit.
# With these limits a single blocking command is killed after a few minutes and the worker
# gets an error back instead of blocking the whole stage.
export BASH_DEFAULT_TIMEOUT_MS="${WORKER_CMD_TIMEOUT_MS:-300000}"
export BASH_MAX_TIMEOUT_MS="${WORKER_CMD_MAX_TIMEOUT_MS:-600000}"

if [ "$MODE" = "read" ]; then
  TOOLS="Read,Glob,Grep"
else
  TOOLS="Read,Glob,Grep,Edit,Write,Bash"
fi

# Guard variant (for /qwen-guard and /qhandoff): WORKER_GUARD=1 loads a PreToolUse hook
# (worker-guard.js: protection patterns, repeat counter, shortened test output) and sets the
# time limit to WORKER_TIMEOUT_MIN (default 30). Without WORKER_GUARD: no hook, 20 minutes.
# The settings file is generated here, so it always points to this installation.
GUARD_ARGS=()
if [ "${WORKER_GUARD:-0}" = "1" ]; then
  GUARD_JS="$HOME/.claude/bin/worker-guard.js"
  command -v cygpath >/dev/null 2>&1 && GUARD_JS=$(cygpath -m "$GUARD_JS")
  GSET="$HOME/.claude/state/worker-guard-settings.json"; mkdir -p "$(dirname "$GSET")"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash|Write|Edit|MultiEdit|Read","hooks":[{"type":"command","command":"node \\"%s\\"","timeout":10}]}]}}\n' "$GUARD_JS" > "$GSET"
  GUARD_ARGS=(--settings "$GSET")
  TMIN="${WORKER_TIMEOUT_MIN:-30}"
  export GUARD_MODE="${GUARD_MODE:-log}"
  export WORKER_RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$HOME/.claude/logs"
else
  TMIN="${WORKER_TIMEOUT_MIN:-20}"
fi
case "$TMIN" in ''|*[!0-9]*) TMIN=20 ;; esac

SYS="You are the worker, not the tech lead."
SYS="$SYS Ignore the 'Local worker' section in CLAUDE.md, never call local-worker.sh and do not delegate anything."
SYS="$SYS Do not start servers, containers or long-running processes: no 'docker run', 'docker compose up',"
SYS="$SYS 'npm start', 'npm run dev', watch modes or background jobs with &."
SYS="$SYS Never write wait or poll loops (while/until with sleep, waiting for a port, a container or a file)."
SYS="$SYS If something needs a running service, do not wait for it: say so in the summary."
SYS="$SYS Do not run end-to-end tests (Playwright, Cypress) and do not read .env files."
SYS="$SYS You only have 40 turns: never read large files (CSS, over 500 lines) in full, but search with Grep"
SYS="$SYS and then read selectively with offset and limit; do not read any file twice."
SYS="$SYS Start changing things after 15 turns at the latest."
SYS="$SYS Finish with a summary of at most 15 lines: what was done, test result, open problems."

if [ -n "${WORKER_ACTIVITY:-}" ] && command -v node >/dev/null 2>&1; then
  # Live transcript: the worker emits its steps as a JSON stream, worker-stream.js writes
  # every tool use to $WORKER_ACTIVITY and only passes on the final report -
  # for the caller the output looks the same as without the transcript.
  timeout "${TMIN}m" claude -p --max-turns 40 --allowedTools "$TOOLS" "${GUARD_ARGS[@]}" --output-format stream-json --verbose \
    --append-system-prompt "$SYS" \
    < "$TASK" 2>&1 | node "$HOME/.claude/bin/worker-stream.js" "$WORKER_ACTIVITY" | tee "$LOG"
  STATUS=${PIPESTATUS[0]}
else
  timeout "${TMIN}m" claude -p --max-turns 40 --allowedTools "$TOOLS" "${GUARD_ARGS[@]}" \
    --append-system-prompt "$SYS" \
    < "$TASK" 2>&1 | tee "$LOG"
  STATUS=${PIPESTATUS[0]}
fi
[ "$STATUS" -eq 124 ] && echo "WORKER-TIMEOUT: aborted after $TMIN minutes" | tee -a "$LOG"
# Guard variant: summary of this run only into the worker log, not to stdout (qwen-first.sh
# evaluates the last lines of stdout as the result)
if [ "${WORKER_GUARD:-0}" = "1" ]; then
  GLOG="$HOME/.claude/logs/worker-guard.log"
  if [ -f "$GLOG" ]; then
    cnt() { grep -F "run=$WORKER_RUN_ID " "$GLOG" | grep -c " $1 "; }
    echo "[guard] run $WORKER_RUN_ID, mode $GUARD_MODE: $(cnt HIT) hits, $(cnt REPEAT) repeat entries," \
      "$(cnt TESTWRAP) shortened test runs, $(cnt HOOK-ERROR) hook errors" >> "$LOG"
  fi
fi
exit "$STATUS"
