#!/usr/bin/env bash
# Usage in the project folder: qwen-small.sh "small task"
# Qwen implements the change on its own, without Claude. Nothing is committed.
set -uo pipefail
TASK="${1:?Usage: qwen-small.sh \"task\"}"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Not a git project, please start in the project folder."; exit 1; }
EXCL="$(git rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$EXCL")"
grep -qx ".worker/" "$EXCL" 2>/dev/null || echo ".worker/" >> "$EXCL"
mkdir -p .worker
F=".worker/small-$(date +%m%d-%H%M%S).md"
{ echo "Implement this small change: $TASK"
  echo "Keep the change as small as possible and follow the style of the surrounding files."
  echo "If there are tests or a linter, run them and fix errors that you caused."
  echo "Do not commit anything."
  if [ -s "$HOME/.claude/worker-lessons.md" ]; then
    echo; echo "Rules from earlier reviews:"; tail -30 "$HOME/.claude/worker-lessons.md"
  fi
} > "$F"
T0=$(date +%s)
bash "$HOME/.claude/bin/local-worker.sh" code "$F" > "${F%.md}.txt" 2>&1
RC=$?
echo "== Report from Qwen"; tail -15 "${F%.md}.txt"
echo "== Changed files"; git status --short

# Into the same run log as /qwen (run-log.js show), so /q and /qwen can be compared.
# "done" only means: Qwen finished without errors - nobody has checked the result.
case "$RC" in 0) RES=done ;; 124) RES=timeout ;; 4) RES=no-server ;; *) RES=aborted ;; esac
LINES=$(git diff HEAD --numstat 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
while IFS= read -r u; do [ -f "$u" ] && LINES=$((LINES + $(wc -l < "$u"))); done \
  < <(git ls-files --others --exclude-standard 2>/dev/null)
node "$HOME/.claude/bin/run-log.js" add "date=$(date '+%Y-%m-%d %H:%M')" "project=$(basename "$PWD")" \
  "kind=q" "result=$RES" "total=$(( $(date +%s) - T0 ))" "lines=$LINES" "cost=0" "task=$TASK" 2>/dev/null
exit "$RC"
