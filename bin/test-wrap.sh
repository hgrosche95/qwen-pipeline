#!/usr/bin/env bash
# Usage (only by worker-guard.js): test-wrap.sh <command as base64>
# Runs a test command of the worker, writes the full output to ~/.claude/logs/ and returns
# only the exit code, notable lines and the last 40 lines to the model.
# The exit code of the test command is preserved.
set -u
CMD=$(printf '%s' "${1:-}" | base64 -d 2>/dev/null)
if [ -z "$CMD" ]; then echo "test-wrap: no command given" >&2; exit 2; fi
DIR="$HOME/.claude/logs/tests"; mkdir -p "$DIR"
OUT="$DIR/test-$(date +%Y%m%d-%H%M%S)-$$.log"
{ echo "# $(date '+%Y-%m-%d %H:%M:%S')  cwd=$PWD"; echo "# \$ $CMD"; } > "$OUT"
bash -c "$CMD" >> "$OUT" 2>&1 < /dev/null
RC=$?
TOTAL=$(($(wc -l < "$OUT") - 2))
echo "Exit code: $RC   ($TOTAL lines of output, complete in $OUT)"
HITS=$(tail -n +3 "$OUT" | grep -nE '[Ee]rror|ERROR|[Ff]ail|FAIL|FAILED|Exception' | head -40)
if [ -n "$HITS" ]; then
  echo "--- Lines with error/fail/Exception (at most 40, with line number):"
  printf '%s\n' "$HITS" | cut -c1-300
fi
echo "--- Last 40 lines:"
tail -n +3 "$OUT" | tail -40 | cut -c1-300
exit "$RC"
