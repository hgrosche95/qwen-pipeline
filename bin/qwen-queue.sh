#!/usr/bin/env bash
# Usage in the project folder: qwen-queue.sh [task file]     (default: .worker/queue.txt)
# Works through several tasks one after another with qwen-first.sh. One task per line; the
# line may start with "/qwen " or "/qwen-no-tests " (as you would type it in the chat),
# empty lines and lines starting with # are skipped.
# Each task builds on the previous one: qwen-first.sh creates its branch from the current
# state, and after a green run that is the branch of the previous task. Nothing changes on
# the starting branch; at the end the whole chain is applied with one command.
# The queue stops at the first task that does not end green - later tasks would otherwise
# build on a broken state.
set -uo pipefail
FILE="${1:-.worker/queue.txt}"
FIRST="${QWEN_FIRST:-$HOME/.claude/bin/qwen-first.sh}"
[ -s "$FILE" ] || { echo "ABORT: The task file $FILE is missing or empty."; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ABORT: Not a git project, please start in the project folder."; exit 1; }

mapfile -t TASKS < <(tr -d '\r' < "$FILE" | grep -vE '^[[:space:]]*(#|$)')
N=${#TASKS[@]}
[ "$N" -gt 0 ] || { echo "ABORT: There is no task in $FILE."; exit 1; }
START=$(git rev-parse --abbrev-ref HEAD)
# One cost log for the whole queue: clear it once here, the single runs keep it.
mkdir -p .worker && : > .worker/usage.log; export KEEP_USAGE=1
LAST=""; GREEN=0; SUMMARY=(); HALT=""
TMP=$(mktemp)

for k in "${!TASKS[@]}"; do
  task="${TASKS[$k]}"; notests=0
  case "$task" in
    "/qwen-no-tests "*)   notests=1; task="${task#/qwen-no-tests }" ;;
    "/qwen-ohne-tests "*) notests=1; task="${task#/qwen-ohne-tests }" ;;
    "/qwen "*)            task="${task#/qwen }" ;;
  esac
  title=$(printf '%s' "$task" | cut -c1-80)
  echo "== Task $((k+1))/$N: $title"
  t0=$(date +%s)
  # The first task gets the normal starting branch check; from the second task on, the run
  # starts from the previous qwen/* branch on purpose
  anyb=0; [ "$k" -gt 0 ] && anyb=1
  ALLOW_ANY_BRANCH=$anyb NO_TESTS=$notests PR=0 bash "$FIRST" "$task" 2>&1 | tee "$TMP"
  rc=${PIPESTATUS[0]}
  mins=$(( ($(date +%s) - t0 + 30) / 60 ))
  branch=$(sed -n 's/^== Done on branch //p' "$TMP" | tail -1)
  if [ "$rc" -eq 0 ] && [ -n "$branch" ] && grep -q '^Test command green' "$TMP" && ! grep -q '^WARNING' "$TMP"; then
    GREEN=$((GREEN+1)); LAST="$branch"
    SUMMARY+=("green, $mins min, $branch: $title")
  else
    SUMMARY+=("NOT GREEN, $mins min${branch:+, $branch}: $title")
    HALT="task $((k+1)) did not end green"
    echo "== Queue halted: $HALT, the remaining $((N-k-1)) tasks were not started"
    break
  fi
done
rm -f "$TMP"

echo
echo "== Queue done: $GREEN of $N tasks green"
for line in "${SUMMARY[@]}"; do echo "   $line"; done
if [ -n "$LAST" ]; then
  echo "   Apply all green tasks: git checkout $START && git merge --squash $LAST"
fi
if [ -n "$HALT" ]; then
  echo "   You are on $(git rev-parse --abbrev-ref HEAD). Back to the starting state: git checkout $START"
fi
[ -z "$HALT" ]
