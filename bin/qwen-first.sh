#!/usr/bin/env bash
# Usage in the project folder: qwen-first.sh "task as a sentence or paragraph"
# Optional: REVIEW_MODEL=sonnet MAX_TRIES=5 qwen-first.sh "..."
# Pull request at the end: start the task with "--pr " or set PR=1 (needs gh, only on a green run)
# Without tests: NO_TESTS=1 qwen-first.sh "..."  (Qwen writes no tests, only build/linter is checked)
# Self-review (stage 5): SELF_REVIEW=auto (default) skips it when all checks are green;
#   SELF_REVIEW=1 always, SELF_REVIEW=0 never.
# Tests (stage 3) are written by TEST_MODEL (default sonnet); TEST_MODEL=qwen has the local
#   worker write them as before. If the model fails, Qwen takes over.
# Large plans (sum of estimated lines above SPLIT_LINES, default 350) are built in two parts
#   with a mid-run review by MID_REVIEW_MODEL (default sonnet). PARTS=1 turns this off,
#   PARTS=2 forces it. STEP_LINES (default 60) is the upper limit per step in the plan.
set -uo pipefail
TASK="${1:?Usage: qwen-first.sh \"task\"}"
PR="${PR:-0}"
case "$TASK" in --pr\ *) PR=1; TASK="${TASK#--pr }" ;; esac
W=.worker
WORKER="$HOME/.claude/bin/local-worker.sh"
RULES="$HOME/.claude/worker-lessons.md"
PLAN_MODEL="${PLAN_MODEL:-opus}"
REVIEW_MODEL="${REVIEW_MODEL:-opus}"
MAX_TRIES="${MAX_TRIES:-3}"
NO_TESTS="${NO_TESTS:-0}"
SELF_REVIEW="${SELF_REVIEW:-auto}"
TEST_MODEL="${TEST_MODEL:-sonnet}"
# No "LF will be replaced by CRLF" warnings in the log (only for this run, changes no git config)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.safecrlf GIT_CONFIG_VALUE_0=false
if [ "$NO_TESTS" = "1" ]; then
  CHECKHINT="Do not write tests and do not change existing ones."
else
  CHECKHINT="Only change tests if a test itself is clearly wrong, and explain why."
fi
touch "$RULES"

# Up front: does the local model server answer? Otherwise plan and tests would already be paid
# for before the first worker step notices the outage. Address from strata.env, as in local-worker.sh.
SCFG="$HOME/.claude/strata.env"; SURL=""
[ -f "$SCFG" ] && SURL=$(sed -n 's/^[[:space:]]*STRATA_URL[[:space:]]*=[[:space:]]*//p' "$SCFG" | tr -d '\r"' | sed 's/[[:space:]]*$//' | tail -1)
SURL="${SURL:-http://127.0.0.1:8080}"; SURL="${SURL%/}"; SURL="${SURL%/v1}"
if [ "${SKIP_SERVER_CHECK:-0}" != "1" ] && [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$SURL/health" 2>/dev/null)" = "000" ]; then
  echo "ABORT: No Strata server is answering at $SURL. Please start the model (strata launch)."
  exit 1
fi

# --- Helper functions --------------------------------------------------------
# Lean Claude call: $1 model, $2 system prompt, $3 name for the log, prompt via stdin.
# The prompt is saved to .worker/prompt-<name>.txt, caching is off (one-off calls).
llm() {
  tee "$W/prompt-$3.txt" | DISABLE_PROMPT_CACHING=1 claude -p --model "$1" --tools "" --max-turns 1 \
    --system-prompt "$2" --output-format json ${LLM_EXTRA:-} | node "$HOME/.claude/bin/usage-log.js" "$3-$1"
}

# Write a worker prompt (stdin -> file $1), append learned rules
wprompt() {
  { cat; echo
    # Without tests (NO_TESTS=1), rules about tests are left out: otherwise they made Qwen
    # build test scripts nobody had asked for.
    if [ "$NO_TESTS" = "1" ]; then
      if tail -30 "$RULES" | grep -qvi 'test'; then
        echo "Rules from earlier reviews, follow them strictly:"; tail -30 "$RULES" | grep -vi 'test'
      fi
    elif [ -s "$RULES" ]; then echo "Rules from earlier reviews, follow them strictly:"; tail -30 "$RULES"; fi
  } > "$1"
}

# Tests from the strong model (stage 3): one Claude run with tools instead of the local worker.
# The tests are the specification for Qwen, so the better model pays off here.
# strong_tests <prompt.md> <output.txt>; returns 1 if the run fails or wrote nothing -
# then Qwen takes over with the same prompt and builds on what is there.
strong_tests() {
  local rc
  # TEST_TURNS limits the turns: each one re-reads the whole history from the cache, which was
  # the biggest cost item (Nov 20: 0.32 of 0.56 USD, 778k cache tokens for ~20 turns of
  # exploring). The prompt now carries the project context, so fewer turns suffice.
  # If it is not enough, Qwen takes over (return 1).
  LOCAL_WORKER_ACTIVE=1 timeout 15m claude -p --model "$TEST_MODEL" --max-turns "${TEST_TURNS:-12}" \
    --allowedTools "Read,Glob,Grep,Edit,Write,Bash" --output-format json \
    --append-system-prompt "You only write tests. Do not change production code, do not commit, do not start servers or long-running processes. Finish with a summary of at most 10 lines." \
    < "$1" 2>&1 | node "$HOME/.claude/bin/usage-log.js" "tests-$TEST_MODEL" > "$2"
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || return 1
  [ -n "$(git status --porcelain)" ]
}

commit() { git add -A && git commit -qm "qwen: $1" >/dev/null 2>&1; return 0; }

# Is the worker output ($1) an outage instead of an answer? Empty, or it ends with an error
# message from the model server - that must never be used as a work result.
worker_failed() {
  local body
  body=$(grep -v '^\[claude-code:' "$1" 2>/dev/null | grep -v '^ *$')
  [ -z "$body" ] && return 0
  printf '%s\n' "$body" | tail -3 | grep -qE '^API Error|engine stopped unexpectedly|Connection error|ECONNREFUSED|^WORKER-RECURSION'
}

# Worker call with outage detection: work <read|code> <prompt.md> <output.txt>
# - Outage (error code, error message, empty answer): one retry after a short pause,
#   the model server restarts on the next call.
# - Time limit or turn limit: up to two continuations in a fresh session that build on
#   what has been changed so far, instead of passing on a half-done result.
# Returns 1 if it stays that way; the output of the last attempt is in $3.
work() {
  local mode="$1" task="$2" out="$3" fails=0 conts=0 rc
  while :; do
    bash "$WORKER" "$mode" "$task" > "$out"; rc=$?
    if [ "$rc" -eq 124 ] || grep -qE '^WORKER-TIMEOUT|Reached max turns' "$out" 2>/dev/null; then
      conts=$((conts+1)); N_TIMEOUT=$((N_TIMEOUT+1))
      if [ "$conts" -gt 2 ]; then echo "   Worker still not done after two continuations"; return 1; fi
      if grep -q 'Reached max turns' "$out" 2>/dev/null; then
        echo "   Worker hit the turn limit, continuation $conts/2 in a fresh session"
      else
        echo "   Worker hit the time limit, continuation $conts/2 in a fresh session"
      fi
      { echo "An earlier session worked on this task and was stopped before it finished."
        echo "First use git status and git diff to see what is already done. Then finish the task"
        echo "without repeating or reverting what is done."
        echo; cat "${task%.cont.md}"
      } > "${task%.cont.md}.cont.md.tmp"
      task="${task%.cont.md}"; mv "$task.cont.md.tmp" "$task.cont.md"; task="$task.cont.md"
    elif [ "$rc" -ne 0 ] || worker_failed "$out"; then
      fails=$((fails+1)); N_FAIL=$((N_FAIL+1))
      if [ "$fails" -gt 1 ]; then return 1; fi
      echo "   Worker failed, retrying"
      sleep 15
    else
      return 0
    fi
  done
}

# The worker stays down: save the state, go back to the starting branch, end the run.
# No review of a half-done state, and the user is not left on a broken branch.
# Exception (SOFT_FAIL=1, while fixing review points): the state before the review fixes was
# complete, so the run falls back to it and ends normally with the points marked as open.
# The half-done fixes are kept on the branch <branch>-partial.
die_worker() {
  local why
  why=$(grep -v '^\[claude-code:' "$2" 2>/dev/null | grep -v '^ *$' | tail -1 | cut -c1-160)
  commit "aborted in $1 (incomplete)"
  if [ "${SOFT_FAIL:-0}" = "1" ] && [ -n "${RFIX_BASE:-}" ]; then
    SOFT_FAIL=0
    git branch -q -f "$BRANCH-partial" HEAD
    git reset -q --hard "$RFIX_BASE"
    RED=${PRE_RED:-0}; RECHECK=fallback
    echo "   Worker failed while fixing review points ($1). ${why:-No answer from the model.}"
    echo "   Back to the state before the review fixes; the partial fixes are on $BRANCH-partial"
    OPEN_NOTE="Review points open: not fixed because the worker failed, see $W/review.md"
    final_wrapup
    exit 0
  fi
  git checkout -q "$PREV" 2>/dev/null
  echo "ABORT: The local worker failed ($1). ${why:-No answer from the model.}"
  echo "   The state so far is on branch $BRANCH, you are back on $PREV."
  exit 1
}

# Runs the quick test command, or RUNCMD if full_check has set it.
# CHECK_TIMEOUT_MIN (default 15) caps every test/check run: a command that starts a server or
# waits for a container would otherwise block the whole pipeline. Exit 124 counts as red.
CHECK_TIMEOUT_MIN="${CHECK_TIMEOUT_MIN:-15}"
case "$CHECK_TIMEOUT_MIN" in ''|*[!0-9]*) CHECK_TIMEOUT_MIN=15 ;; esac
run_check() {
  timeout "${CHECK_TIMEOUT_MIN}m" bash -c "$1" < /dev/null; local rc=$?
  [ "$rc" -eq 124 ] && echo "CHECK-TIMEOUT: '$1' was stopped after $CHECK_TIMEOUT_MIN minutes (does it start a server or wait for something?)"
  return "$rc"
}
RUNCMD=""
run_tests() { run_check "${RUNCMD:-$TESTCMD}" > "$W/test.txt" 2>&1; }

# Qwen fixes until the tests are green (at most MAX_TRIES attempts)
fix_loop() {
  local n=0 cmd="${RUNCMD:-$TESTCMD}"
  while ! run_tests; do
    n=$((n+1)); [ "$n" -gt "$MAX_TRIES" ] && return 1
    N_FIX=$((N_FIX+1))
    echo "   Tests red, fix attempt $n/$MAX_TRIES"
    { echo "The test command '$cmd' fails. Find the cause and fix it."
      echo "Keep the fix as small as possible and stick to what the task and plan require."
      echo "$CHECKHINT"
      echo "Then run the test command until it is green."
      echo; echo "Task: $TASK"; echo; echo "Last test output:"; tail -60 "$W/test.txt"
    } | wprompt "$W/fix-$1-$n.md"
    work code "$W/fix-$1-$n.md" "$W/fix-$1-$n.txt" || die_worker "fix $1/$n" "$W/fix-$1-$n.txt"
    commit "Fix $1/$n"
  done
  return 0
}

# Full check: everything the project's CI checks (CHECKCMD from the plan), not just the quick
# test command. Qwen fixes as in fix_loop. Without CHECKCMD, or if nothing was committed since
# the last green full check, nothing happens.
CHECKCMD=""; CHECKED_AT=""
full_check() {
  local cmd="$CHECKCMD"
  # A changed Dockerfile is not built by any CI check: build it here, if Docker is running
  if [ -f Dockerfile ] && git diff --name-only "$BASE" HEAD 2>/dev/null | grep -qE '^(Dockerfile|\.dockerignore)$'; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      cmd="${cmd:+$cmd && }docker build -q ."
    else
      echo "   Note: Dockerfile changed, but Docker is not running, so it is not built"
    fi
  fi
  [ -z "$cmd" ] && return 0
  [ "$(git rev-parse HEAD 2>/dev/null)" = "$CHECKED_AT" ] && return 0
  echo "   Full check running: $cmd"
  RUNCMD="$cmd"; fix_loop "$1"; local r=$?; RUNCMD=""
  if [ "$r" -eq 0 ]; then CHECKED_AT=$(git rev-parse HEAD 2>/dev/null); else echo "   Full check stays red"; fi
  return "$r"
}

# Review points to Qwen: fix_points <points file> <prefix> <commit name>
# The points go in groups of REVIEW_BATCH (default 3) to one fresh session each:
# eight points at once ran into the time limit twice. Text before the first numbered
# point belongs to no group; if there are no numbers, everything goes into one session.
fix_points() {
  local src="$1" tag="$2" label="$3" per="${REVIEW_BATCH:-3}" pre="$W/$2-part" npts parts b
  rm -f "$pre"*.md
  npts=$(grep -cE '^[0-9]+\. ' "$src")
  if [ "$npts" -gt "$per" ]; then
    awk -v per="$per" -v pre="$pre" '/^[0-9]+\. /{n++} n>0{print > sprintf("%s%d.md", pre, int((n-1)/per)+1)}' "$src"
  else
    cp "$src" "${pre}1.md"
  fi
  parts=$(ls "$pre"*.md | wc -l)
  b=1
  while [ "$b" -le "$parts" ]; do
    [ "$parts" -gt 1 ] && echo "   Review part $b/$parts"
    { echo "Fix these review points completely and then run '$TESTCMD' until it is green:"
      echo "Keep every fix as small as possible. Do not add new features or new tests,"
      echo "unless a review point explicitly asks for it."
      [ "$parts" -gt 1 ] && echo "This is part $b of $parts: fix only the points below, the others are or will be handled separately."
      cat "${pre}$b.md"; echo; echo "Task: $TASK"; echo; cat "$W/plan-head.md"
    } | wprompt "$W/q6-$tag-fix$b.md"
    work code "$W/q6-$tag-fix$b.md" "$W/$tag-fix$b.txt" || die_worker "fixing $label ($b/$parts)" "$W/$tag-fix$b.txt"
    if [ "$parts" -gt 1 ]; then commit "$label $b/$parts"; else commit "$label"; fi
    b=$((b+1))
  done
}

# Mid-run check after step SPLIT: make the tests green, then a cheaper review of only the
# first part, have Qwen fix the points. Afterwards MID_BASE sets the base for the final
# review, which then only reads the second part. If the review fails, MID_BASE stays empty
# and the final review sees the whole diff as before.
MID_BASE=""
mid_review() {
  local model="${MID_REVIEW_MODEL:-sonnet}" rest
  mark midcheck
  echo "== Mid-run check after step $SPLIT/$STEPS by $model"
  fix_loop m || echo "   Intermediate state stays red, continuing with part 2"
  rest=$(grep '^## Step ' "$W/plan.md" | sed -n "$((SPLIT+1)),\$p" | sed 's/^## /- /')
  { echo "Task: $TASK"; echo; echo "Plan:"; cat "$W/plan.md"; echo; devnote
    echo "This is a mid-run check: steps 1 to $SPLIT of $STEPS are implemented."
    echo "These steps only come afterwards and are missing on purpose, do not count them as a gap:"
    echo "$rest"; echo
    echo "Check command '$TESTCMD': $(tail -3 "$W/test.txt" 2>/dev/null | tr '\n' ' ')"; echo
    echo "Changed files:"; git diff --stat "$BASE" | tail -40; echo
    echo "Diff (without lockfiles, truncated if too long):"
    git diff "$BASE" -- . ':(exclude)*.lock' ':(exclude)package-lock.json' | head -c 50000; echo
    echo "List only real bugs in this diff against the task and the plan for steps 1 to $SPLIT,"
    echo "as a numbered list with file and concrete fix. No extensions, nothing that anticipates"
    echo "later steps, no bugs that already existed before."
    [ "$NO_TESTS" = "1" ] && echo "No tests were ordered on purpose: do not ask for any."
    echo "If a bug is typical for weaker developers, append at most two lines at the end"
    echo "in the format 'RULE: <general, project-independent rule>'."
    echo "If everything is fine, answer only: OK"
  } | llm "$model" "You are a code reviewer. Answer directly and concisely." midreview > "$W/review-mid.md"
  if ! grep -q '[^[:space:]]' "$W/review-mid.md"; then
    echo "   Mid-run check failed, skipping it"; return 0
  fi
  grep '^RULE:' "$W/review-mid.md" | sed 's/^RULE: */- /' >> "$RULES"
  if grep -qx "OK" "$W/review-mid.md" || ! grep -qE '^[0-9]+\. ' "$W/review-mid.md"; then
    echo "== Mid-run check: OK"
  else
    grep -v '^RULE:' "$W/review-mid.md" > "$W/review-mid-points.md"
    echo "== Qwen fixes the mid-run check points"
    fix_points "$W/review-mid-points.md" mid "Mid-run review"
    fix_loop n || echo "   Intermediate state stays red, continuing with part 2"
  fi
  MID_BASE=$(git rev-parse --short HEAD)
}

# --- Preparation -------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  git init -q && git add -A && git commit -q --allow-empty -m "Initial state"
elif ! git rev-parse HEAD >/dev/null 2>&1; then
  git add -A && git commit -q --allow-empty -m "Initial state"
fi
EXCL="$(git rev-parse --git-dir)/info/exclude"; mkdir -p "$(dirname "$EXCL")"
grep -qx ".worker/" "$EXCL" 2>/dev/null || echo ".worker/" >> "$EXCL"
# Claude Code creates local files under .claude/ in every project, which would otherwise block
# the run as "uncommitted". If the project versions nothing under .claude/, the whole folder is
# excluded locally, otherwise only the purely local files. This changes no versioned file
# (.git/info/exclude is local).
if [ -z "$(git ls-files .claude 2>/dev/null | head -1)" ]; then
  CLAUDE_EXCL=".claude/"
else
  CLAUDE_EXCL=".claude/settings.local.json .claude/scheduled_tasks.lock"
fi
for e in $CLAUDE_EXCL; do grep -qxF "$e" "$EXCL" 2>/dev/null || echo "$e" >> "$EXCL"; done
if [ -n "$(git status --porcelain)" ]; then
  echo "There are uncommitted changes. Please commit or stash them first."; exit 1
fi
BASE=$(git rev-parse --short HEAD 2>/dev/null) || { echo "Git commit not possible. Are user.name and user.email set?"; exit 1; }
PREV=$(git rev-parse --abbrev-ref HEAD)
# Starting branch check: the run branches off whatever is checked out. That was sometimes a
# PR branch that had already been merged, so the work ended up on a stale base. Abort if the
# current branch looks like that; ALLOW_ANY_BRANCH=1 skips the check.
branch_problem() {
  local def up
  [ "$PREV" = "HEAD" ] && { echo "HEAD is detached (no branch checked out)"; return 0; }
  case "$PREV" in qwen/*) echo "'$PREV' is a branch of an earlier qwen run"; return 0 ;; esac
  up=$(git for-each-ref --format='%(upstream:track)' "refs/heads/$PREV" 2>/dev/null)
  [ "$up" = "[gone]" ] && { echo "the remote branch of '$PREV' was deleted (typical after a merged PR)"; return 0; }
  # Default branch: origin/HEAD if known, otherwise main or master
  def=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  [ -z "$def" ] && for c in origin/main origin/master main master; do
    git rev-parse -q --verify "$c" >/dev/null 2>&1 && { def=$c; break; }
  done
  [ -z "$def" ] && return 1
  [ "${def#origin/}" = "$PREV" ] && return 1
  # Fully contained in the default branch and not ahead of it: merged (normal merge or rebase)
  if [ "$(git rev-parse "$PREV")" != "$(git rev-parse "$def")" ] \
    && git merge-base --is-ancestor "$PREV" "$def" 2>/dev/null; then
    echo "'$PREV' is already merged into $def"; return 0
  fi
  return 1
}
if [ "${ALLOW_ANY_BRANCH:-0}" != "1" ] && WHY=$(branch_problem); then
  echo "ABORT: Not starting from this branch: $WHY."
  echo "   Switch to the branch the work should be based on (e.g. git checkout main && git pull),"
  echo "   or start anyway: ALLOW_ANY_BRANCH=1 qwen-first.sh \"...\""
  exit 1
fi
BRANCH="qwen/$(date +%m%d-%H%M%S)"
git checkout -q -b "$BRANCH" || exit 1
mkdir -p "$W"

# --- Metrics -----------------------------------------------------------------
# Each stage sets a timestamp (mark <name>). At the end of the run, even on an abort,
# finish writes one line to ~/.claude/qwen-runs.jsonl: duration per stage, time limits,
# fix attempts, review points, diff size, cost. View: node ~/.claude/bin/run-log.js show
RUNLOG="$HOME/.claude/bin/run-log.js"
RUN_T0=$(date +%s); : > "$W/timing.log"
N_TIMEOUT=0; N_FAIL=0; N_FIX=0; NPTS=0; NOUT=0; RECHECK="-"; RUN_DONE=0; RED=0; STEPS=0
mark() { echo "$(date +%s) $1" >> "$W/timing.log"; }
# Cost before this run; re-read after usage.log is cleared (below)
COST0=0
finish() {
  [ -n "${RUN_LOGGED:-}" ] && return 0; RUN_LOGGED=1
  local now durs cost lines result
  now=$(date +%s); echo "$now end" >> "$W/timing.log"
  durs=$(awk 'NR>1{d[p]+=$1-t} {t=$1;p=$2} END{for(k in d) printf "t_%s=%d ", k, d[k]}' "$W/timing.log")
  cost=$(node "$RUNLOG" cost 2>/dev/null || echo 0)
  cost=$(awk -v a="$cost" -v b="$COST0" 'BEGIN{c=a-b; if(c<0)c=a; printf "%.4f", c}')
  lines=$(git diff --numstat "$BASE" "$BRANCH" 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
  if [ "$RUN_DONE" != "1" ]; then result=aborted; elif [ "$RED" -eq 1 ]; then result=red; else result=green; fi
  # shellcheck disable=SC2086
  node "$RUNLOG" add "date=$(date '+%Y-%m-%d %H:%M')" "project=$(basename "$PWD")" "branch=$BRANCH" \
    "result=$result" "total=$((now-RUN_T0))" $durs "steps=$STEPS" "timeouts=$N_TIMEOUT" "fails=$N_FAIL" \
    "fixes=$N_FIX" "review_points=$NPTS" "out_of_scope=$NOUT" "recheck=$RECHECK" "lines=$lines" "cost=$cost" \
    "no_tests=$NO_TESTS" "test_model=$TEST_MODEL" "self_review=$SELF_REVIEW" "task=$TASK" 2>/dev/null
  # Final line for qwen-progress.sh: the run is over, however it ended
  echo "== End"
  return 0
}
trap finish EXIT
# Live transcript: local-worker.sh writes every tool use of the worker here,
# qwen-progress.sh turns it into progress updates.
export WORKER_ACTIVITY="$PWD/$W/activity.log"; : > "$WORKER_ACTIVITY"
# Start the cost log fresh for each run, so the SUM at the end only shows this run. A queue
# can clear it once itself and set KEEP_USAGE=1.
[ "${KEEP_USAGE:-0}" = "1" ] || : > "$W/usage.log"
# Only now remember the starting cost: before this, it would still hold the previous run's sum,
# which would then be subtracted from this run (0 after clearing, in a queue the earlier runs)
COST0=$(node "$RUNLOG" cost 2>/dev/null || echo 0)

# --- 1 Context: by script, for larger projects additionally by Qwen ----------
mark context
echo "== 1/6 Gathering context"
NFILES=$(git ls-files | wc -l)
if [ "$NFILES" -eq 0 ]; then
  echo "EMPTY PROJECT" > "$W/context.txt"
else
  { echo "Files ($NFILES):"; git ls-files | head -150
    for f in package.json pyproject.toml composer.json Makefile README.md; do
      [ -f "$f" ] && { echo; echo "--- $f (beginning)"; head -40 "$f"; }
    done
    # CI workflows: the plan derives the full check (CHECK) from these
    for f in $(ls .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null | head -4); do
      echo; echo "--- $f (beginning)"; head -200 "$f"
    done
  } > "$W/context.txt"
  if [ "$NFILES" -gt 40 ]; then
    echo "   Project is larger, Qwen explores"
    { echo "User's task: $TASK"
      echo "Explore this project read-only. Answer with at most 60 lines:"
      echo "the files relevant to the task with one sentence each, important functions"
      echo "and interfaces with signatures, existing conventions, test commands."
    } | wprompt "$W/q1-explore.md"
    if work read "$W/q1-explore.md" "$W/explore.txt"; then
      { echo; echo "Exploration:"; tail -70 "$W/explore.txt"; } >> "$W/context.txt"
    else
      echo "   Exploration failed, the plan is written without it"
    fi
  fi
fi

# --- 2 Plan ------------------------------------------------------------------
mark plan
echo "== 2/6 $PLAN_MODEL is planning"
{ echo "Task: $TASK"; echo; echo "Project context:"; cat "$W/context.txt"; echo
  echo "Write an implementation plan for a weaker developer, at most 100 lines,"
  echo "exactly in this format:"
  if [ "$NO_TESTS" = "1" ]; then
    echo "TEST: <one command that checks the project still builds (build, type check or linter,"
    echo " whatever the project already has) and exits with 0 on success. If there is none: TEST: true>"
  else
    echo "TEST: <one command that runs all tests and exits with 0 on success>"
  fi
  echo "CHECK: <one single command that checks everything the project's CI checks and TEST does not"
  echo " cover: linters, type checks, builds and the tests of all subprojects, chained with &&,"
  echo " subfolders as (cd folder && ...). Take the commands literally from the CI workflows in the"
  echo " project context, without install, login and deploy steps. Exits with 0 on success."
  echo " If there is no CI or it checks nothing beyond TEST: CHECK: none>"
  echo "SPLIT: <'after step K' or 'none', see rules>"
  echo "## General"
  echo "<Architecture decisions and pitfalls, at most 12 lines. Explicitly define the data model"
  echo " and edge cases here that a weaker developer would otherwise guess wrong.>"
  echo "## Step 1: <title>"
  echo "Size: ~<estimated changed lines, including CSS> lines in <files>"
  echo "<Files, signatures and interfaces, acceptance criteria as testable statements>"
  if [ "$NO_TESTS" = "1" ]; then
    echo "Do not plan any tests: none will be written."
  else
    echo "Test file: <one path. Preferably an existing test file that already contains related tests"
    echo " (e.g. the one for the changed module); a new one only if there is no suitable one>"
    echo "Tests: <one test name per line and exactly what it checks, with concrete values>"
  fi
  echo "## Step 2: <title>"
  echo "Rules: 2 to 8 steps, each self-contained and building on the previous one."
  echo "The developer has only 40 tool calls and 20 minutes per step: a step changes"
  echo "at most about ${STEP_LINES:-60} lines in at most 2 files, otherwise split it. Estimate the"
  echo "size honestly, including styles and types. If all steps together add up to more than about"
  echo "${SPLIT_LINES:-350} lines, set SPLIT to the step after which a first part that runs on its own"
  echo "is done (roughly half): that is where it gets checked and reviewed in between."
  echo "Otherwise SPLIT: none. No code except signatures. No introduction, no closing words."
  echo "Do not plan a separate step for checking, verifying or for the full check:"
  echo "the script runs TEST and CHECK itself after the steps."
  echo "Choose the smallest solution that fulfills the task: no features, output formats"
  echo "or configuration changes that the task does not ask for."
  echo "Existing functions may be refactored if that enables reuse instead of rebuilding;"
  echo "then name the file and the new signature."
} | llm "$PLAN_MODEL" "You are a software architect. Answer directly and concisely." plan > "$W/plan.md"

TESTCMD=$(grep -m1 -i '^TEST:' "$W/plan.md" | sed 's/^[Tt][Ee][Ss][Tt]: *//; s/`//g')
STEPS=$(grep -c '^## Step ' "$W/plan.md")
if [ -z "$TESTCMD" ] || [ "$STEPS" -eq 0 ]; then
  echo "Plan does not have the expected format, see $W/plan.md"; exit 1
fi
awk '/^## Step /{exit} {print}' "$W/plan.md" > "$W/plan-head.md"
echo "   $STEPS steps, test command: $TESTCMD"
CHECKCMD=$(grep -m1 -i '^CHECK:' "$W/plan.md" | sed 's/^[Cc][Hh][Ee][Cc][Kk]: *//; s/`//g; s/ *$//')
case "$CHECKCMD" in none|None|NONE|-|"$TESTCMD") CHECKCMD="" ;; esac
[ -n "$CHECKCMD" ] && echo "   Full check: $CHECKCMD"

# Size and split: Opus estimates the changed lines per step. Large plans are built in two
# parts, with a mid-run check and review after the first (run on Nov 18: 5 steps, ~600 lines,
# two continuations and 6 review points at the end). PARTS=1 turns the split off, PARTS=2
# forces it. If Opus gives no split for a large plan, the script splits on its own.
SIZES=$(awk '/^## Step /{c++; s[c]=0} c && /^Size:/{ if (match($0, /[0-9]+/)) s[c]=substr($0, RSTART, RLENGTH) }
  END{for (i=1; i<=c; i++) printf "%d ", s[i]}' "$W/plan.md")
TOTAL=0; for s in $SIZES; do TOTAL=$((TOTAL+s)); done
SPLIT=$(grep -m1 -i '^SPLIT:' "$W/plan.md" | sed -n 's/.*[Ss]tep *\([0-9][0-9]*\).*/\1/p')
case "$SPLIT" in ''|*[!0-9]*) SPLIT=0 ;; esac
# Middle by size: first step at which half is reached (without sizes: middle step)
mid_step() {
  local i=0 acc=0 s
  if [ "$TOTAL" -le 0 ]; then echo $(( (STEPS+1)/2 )); return; fi
  for s in $SIZES; do i=$((i+1)); acc=$((acc+s)); [ $((acc*2)) -ge "$TOTAL" ] && break; done
  echo "$i"
}
case "${PARTS:-auto}" in
  1) SPLIT=0 ;;
  2) [ "$SPLIT" -eq 0 ] && SPLIT=$(mid_step) ;;
  *) [ "$SPLIT" -eq 0 ] && [ "$TOTAL" -gt "${SPLIT_LINES:-350}" ] && [ "$STEPS" -ge 3 ] && SPLIT=$(mid_step) ;;
esac
# After the last step, the mid-run check would just be a duplicate final review
[ "$SPLIT" -ge "$STEPS" ] && SPLIT=$((STEPS-1))
[ "$STEPS" -lt 2 ] && SPLIT=0
if [ "$SPLIT" -gt 0 ]; then
  echo "   Size: ~$TOTAL lines, two parts with a mid-run check after step $SPLIT"
elif [ "$TOTAL" -gt 0 ]; then
  echo "   Size: ~$TOTAL lines, one part"
fi

mark baseline
# Check the starting state: if the test command is already red before the change, Qwen would
# "fix" someone else's bugs (or configure them away). Better to abort and ask.
if [ "$NFILES" -gt 0 ] && [ "${ALLOW_RED_BASE:-0}" != "1" ] && ! run_tests; then
  echo "ABORT: '$TESTCMD' is already red at the starting state. Last output:"
  tail -15 "$W/test.txt"
  echo "Please fix it first or narrow down the test command in the task."
  echo "Start anyway: ALLOW_RED_BASE=1 qwen-first.sh \"...\"   (plan is in $W/plan.md)"
  git checkout -q - && git branch -q -D "$BRANCH"
  exit 1
fi
# The same for the full check, just without aborting: if it is already red before (or cannot
# run here), it says nothing about the change and is skipped for this run.
if [ -n "$CHECKCMD" ] && [ "$NFILES" -gt 0 ] && ! run_check "$CHECKCMD" > "$W/check-base.txt" 2>&1; then
  echo "   Full check is already red at the starting state and is skipped, see $W/check-base.txt"
  CHECKCMD=""
fi

mark tests
: > "$W/deviations.md"
# --- 3 Tests first -----------------------------------------------------------
if [ "$NO_TESTS" = "1" ]; then
echo "== 3/6 skipped (NO_TESTS=1)"
else
if [ "$TEST_MODEL" = "qwen" ]; then echo "== 3/6 Qwen writes the tests"; else echo "== 3/6 $TEST_MODEL writes the tests"; fi
{ echo "Write only the automated tests for this plan, no implementation yet."
  echo "Write exactly the tests listed in the plan under 'Tests:', no others and no"
  echo "duplicates. The tests may fail for now."
  echo "Set up the test tool if needed, so that '$TESTCMD' can run."
  echo "Write the tests into the file the plan names for each step under 'Test file:'."
  echo "The project context below is already explored: do not explore the project again."
  echo "Read only the files named in the plan and the test file (for fixtures, helpers and"
  echo "style), and run the tests at most once."
  echo "The plan was written without seeing the code. If the code contradicts the plan (status"
  echo "codes, response formats, names, signatures), test the real behavior and end your answer"
  echo "with a section exactly like this, one line per contradiction:"
  echo "PLAN-DEVIATIONS:"
  echo "- <file>: plan says <X>, code actually does <Y>"
  echo "If there is no contradiction, end with the line: PLAN-DEVIATIONS: none"
  echo; echo "Task: $TASK"; echo; cat "$W/plan.md"
  echo; echo "Project context:"; cat "$W/context.txt"
} | wprompt "$W/q3-tests.md"
if [ "$TEST_MODEL" = "qwen" ] || ! strong_tests "$W/q3-tests.md" "$W/tests.txt"; then
  [ "$TEST_MODEL" = "qwen" ] || echo "   Test model $TEST_MODEL failed, Qwen writes the tests"
  work code "$W/q3-tests.md" "$W/tests.txt" || die_worker "writing tests" "$W/tests.txt"
fi
commit "Tests"
# Plan deviations found while writing the tests go into every later prompt (via plan-head.md
# and the reviews): on Nov 20 the plan said 404, the code returned 400, the test model
# noticed it, but Qwen and the reviewer never heard of it and it became 2 review points.
awk '/^PLAN-DEVIATIONS:/{f=1; next} f && /^[[:space:]]*[-*] /{print}' "$W/tests.txt" \
  | sed 's/^[[:space:]]*\* /- /' | head -12 > "$W/deviations.md"
NDEV=$(grep -c '' "$W/deviations.md")
if [ "$NDEV" -gt 0 ]; then
  { echo; echo "## Facts found while writing the tests (they take precedence over the plan)"
    cat "$W/deviations.md"; } >> "$W/plan-head.md"
  echo "   Tests found $NDEV plan deviation(s), passed on to all later steps"
fi
fi
# Deviations section for the review prompts (empty if there are none)
devnote() {
  [ -s "$W/deviations.md" ] || return 0
  echo "Facts found while writing the tests; they take precedence over the plan, so code that"
  echo "follows them instead of the plan is correct:"; cat "$W/deviations.md"; echo
}

# --- 4 Implementation step by step, each in a fresh session ------------------
mark steps
i=1
while [ "$i" -le "$STEPS" ]; do
  echo "== 4/6 Qwen implements step $i/$STEPS"
  { echo "Implement exactly this one step completely. Earlier steps are already done,"
    if [ "$NO_TESTS" = "1" ]; then
      echo "later ones come afterwards. Then run '$TESTCMD' and fix errors that you"
      echo "caused. $CHECKHINT"
    else
      echo "later ones come afterwards. The tests already exist: run '$TESTCMD' and make sure"
      echo "the tests for this step are green. $CHECKHINT"
    fi
    echo; echo "Task: $TASK"; echo; cat "$W/plan-head.md"; echo
    awk -v n="$i" '/^## Step /{c++} c==n' "$W/plan.md"
  } | wprompt "$W/q4-step$i.md"
  work code "$W/q4-step$i.md" "$W/step$i.txt" || die_worker "step $i" "$W/step$i.txt"
  commit "Step $i"
  [ "$i" -eq "$SPLIT" ] && mid_review
  i=$((i+1))
done

# --- Test loop, escalation only if Qwen gets stuck ---------------------------
mark checks
RED=0
if ! fix_loop a; then
  echo "== Escalation: $PLAN_MODEL gives a hint"
  { echo "Task: $TASK"; echo; cat "$W/plan-head.md"; echo
    echo "A weaker developer cannot get the tests green. Test output:"
    tail -60 "$W/test.txt"; echo; echo "Diff so far:"; git diff "$BASE" | head -c 40000; echo
    echo "Name the cause and the concrete fix with file and location, at most 25 lines."
  } | llm "$PLAN_MODEL" "You are a senior developer. Answer directly and concisely." hint > "$W/hint.md"
  { echo "Apply this hint and then run '$TESTCMD' until it is green:"
    cat "$W/hint.md"; echo; echo "Task: $TASK"
  } | wprompt "$W/q-hint.md"
  work code "$W/q-hint.md" "$W/hint.txt" || die_worker "applying hint" "$W/hint.txt"
  commit "Hint applied"
  fix_loop b || RED=1
fi
# Only now everything the CI checks: so both reviews see the result instead of guessing
if [ "$RED" -eq 0 ]; then full_check g || RED=1; fi

# --- 5 Self-review by Qwen in a fresh session --------------------------------
# It costs 10 to 40 minutes. If the checks are green, it adds little next to the final
# review and is skipped (SELF_REVIEW=auto), also with NO_TESTS=1: there, in the run on
# Nov 16, it rebuilt tests nobody had ordered and still did not prevent the review points.
DO_SELF=1
case "$SELF_REVIEW" in
  0) DO_SELF=0 ;;
  1) DO_SELF=1 ;;
  *) if [ "$RED" -eq 0 ]; then DO_SELF=0; fi ;;
esac
git diff "$BASE" > "$W/diff.patch"
if [ "$DO_SELF" -eq 0 ]; then
if [ "$SELF_REVIEW" = "0" ]; then
  echo "== 5/6 skipped (SELF_REVIEW=0)"
else
  echo "== 5/6 skipped (checks green)"
fi
else
mark selfreview
echo "== 5/6 Qwen reviews its own diff"
{ echo "You are a reviewer and did not write this code. Read $W/diff.patch and the"
  echo "affected files. Check against the task and plan: bugs, forgotten acceptance criteria,"
  echo "unhandled edge cases, dead or duplicate code. List only points you can prove, as a"
  echo "numbered list with file and fix. If everything is fine, answer only: OK"
  echo "The yardstick is the task and the plan, not what else could be improved: do not suggest"
  echo "extensions (new fields, metrics, outputs, refactorings) that neither asks for,"
  echo "and no solution that contradicts the plan. Changes in the diff that go beyond the task and"
  echo "plan are a point themselves: revert them. If the change breaks something outside the"
  echo "plan's files, name the smallest fix at exactly that location."
  echo "You cannot run commands. The checks have already run, the result is below:"
  echo "do not recompute by hand what they already prove."
  echo; echo "Task: $TASK"; echo; cat "$W/plan.md"; echo; devnote
  echo; echo "Checks: test command '$TESTCMD'${CHECKCMD:+, full check '$CHECKCMD'}."
  if [ "$RED" -eq 1 ]; then echo "State: RED. Last output:"; else echo "State: green. Last output:"; fi
  tail -15 "$W/test.txt"
} | wprompt "$W/q5-selfreview.md"
# If the reviewer fails, there are no findings: then continue to the final review without
# self-review, instead of having an error message "fixed" as a review point.
SELF_OK=1
work read "$W/q5-selfreview.md" "$W/selfreview.txt" || SELF_OK=0
[ "$SELF_OK" -eq 0 ] && echo "   Self-review failed, skipping it"
if [ "$SELF_OK" -eq 1 ] && ! tail -3 "$W/selfreview.txt" | grep -qx "OK"; then
  { echo "A reviewer found these points. Check each point against the code and fix the"
    echo "valid ones. Then run '$TESTCMD' until it is green."
    echo "A point is only valid if it proves a bug against the task or the plan."
    echo "The plan takes precedence over the reviewer: do not implement anything that contradicts"
    echo "it or goes beyond it (new fields, metrics, refactorings). Only change files the plan does"
    echo "not name if the change demonstrably broke something there, and then with the"
    echo "smallest fix. Keep every fix as small as possible."
    echo; tail -40 "$W/selfreview.txt"; echo; echo "Task: $TASK"; echo; cat "$W/plan.md"
  } | wprompt "$W/q5-selffix.md"
  work code "$W/q5-selffix.md" "$W/selffix.txt" || die_worker "fixing self-review" "$W/selffix.txt"
  commit "Self-review"
  fix_loop c || RED=1
fi
fi

# --- End of the run: last full check, summary, optional PR ----------------------
# A function, so die_worker can also end a run here after falling back (SOFT_FAIL=1).
final_wrapup() {
  mark final
  # Last full check, in case self-review or review still changed something
  if [ "$RED" -eq 0 ]; then full_check h || RED=1; fi
  echo
  if [ "$RED" -eq 1 ]; then
    echo "WARNING: Tests are still red, see $W/test.txt"
  else
    echo "Test command green: $TESTCMD"
    [ -n "$CHECKCMD" ] && echo "Full check green: $CHECKCMD"
  fi
  RUN_DONE=1
  echo "== Done on branch $BRANCH"
  echo "   View:    git diff $BASE --stat"
  echo "   Plan:    $W/plan.md    Review: $W/review.md"
  echo "   Apply:   git checkout - && git merge --squash $BRANCH && git branch -D $BRANCH"
  [ "$NOUT" -gt 0 ] && echo "   Out of scope: $NOUT point(s), not fixed, see $W/later.md"
  [ -n "${OPEN_NOTE:-}" ] && echo "   $OPEN_NOTE"
  # --- Optional: pull request (no model, just git and gh) ----------------------
  if [ "$PR" = "1" ]; then
    if [ "$RED" -eq 1 ]; then
      echo "== No PR: the test command is red"
    elif ! git remote get-url origin >/dev/null 2>&1; then
      echo "== No PR: this project has no remote 'origin'"
    elif ! command -v gh >/dev/null 2>&1; then
      echo "== No PR: gh is not installed"
    else
      { echo "Created by qwen-first.sh: a local model builds, $PLAN_MODEL plans, $REVIEW_MODEL reviews."
        echo; echo "## Task"; echo "$TASK"
        echo; echo "## Test command"; echo "\`$TESTCMD\` (green)"
        [ -n "$CHECKCMD" ] && { echo; echo "## Full check"; echo "\`$CHECKCMD\` (green)"; }
        echo; echo "## Plan"; cat "$W/plan.md"
        echo; echo "## Review"; cat "$W/review.md"
      } > "$W/pr-body.md"
      TITLE=$(printf '%s' "$TASK" | head -1 | cut -c1-70)
      BASEARG=()
      if git ls-remote --exit-code --heads origin "$PREV" >/dev/null 2>&1; then
        BASEARG=(--base "$PREV")
      else
        echo "   Note: '$PREV' does not exist on GitHub, the PR targets the default branch"
      fi
      if git push -q -u origin "$BRANCH" \
        && gh pr create "${BASEARG[@]}" --head "$BRANCH" --title "$TITLE" --body-file "$W/pr-body.md"; then
        echo "== Pull request created"
      else
        echo "== PR could not be created (push or gh failed), the branch stays local"
      fi
    fi
  fi
}

# --- 6 Final review ----------------------------------------------------------
# Test hook: REVIEW_BASE=<commit> makes the review check from that state instead of from the
# start of the run (for the review test with deliberately planted bugs). Without the variable,
# nothing changes.
RBASE="${REVIEW_BASE:-${MID_BASE:-$BASE}}"
# Take test files out of the review diff, they are often the biggest part
TESTPAT='(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.|(^|/)test_|_test\.'
mapfile -t SRC < <(git diff --name-only "$RBASE" | grep -Ev "$TESTPAT")
NTEST=$(git diff --name-only "$RBASE" | grep -Ec "$TESTPAT")
[ "${#SRC[@]}" -eq 0 ] && SRC=(.)
# Small diffs with green tests are reviewed by a cheaper model
NLINES=$(git diff "$RBASE" -- "${SRC[@]}" | wc -l)
if [ "$NLINES" -lt 150 ] && [ "$RED" -eq 0 ]; then REVIEW_MODEL="${SMALL_REVIEW_MODEL:-sonnet}"; fi
mark review
echo "== 6/6 $REVIEW_MODEL reviews"
{ echo "Task: $TASK"; echo; echo "Plan:"; cat "$W/plan.md"; echo; devnote
  [ "$RED" -eq 1 ] && { echo "WARNING: The tests are still red:"; tail -30 "$W/test.txt"; echo; }
  [ -n "$CHECKCMD" ] && [ "$RED" -eq 0 ] && { echo "Full check (like the CI) is green: $CHECKCMD"; echo; }
  if [ -n "$MID_BASE" ] && [ -z "${REVIEW_BASE:-}" ]; then
    echo "Steps 1 to $SPLIT have already been reviewed and fixed in a mid-run check."
    echo "The diff below only shows what came after. Review it, and whether it fits the first part."
    echo "All files of the run:"; git diff --stat "$BASE" | tail -40; echo
  fi
  echo "Changed files:"; git diff --stat "$RBASE" | tail -40; echo
  echo "New tests (names only):"; git diff "$RBASE" | grep -E '^\+.*(def test_|it\(|test\()' | head -60; echo
  echo "Diff (without test files and lockfiles, truncated if too long, $NTEST test files changed):"
  git diff "$RBASE" -- "${SRC[@]}" ':(exclude)*.lock' ':(exclude)package-lock.json' | head -c 60000; echo
  echo "List only real bugs and gaps as a numbered list with file and concrete fix."
  echo "If a point has nothing to do with the task (a pre-existing bug in code the task does"
  echo "not ask for), write 'OUT-OF-SCOPE:' right after the number, e.g."
  echo "'3. OUT-OF-SCOPE: file.py ...'. Such points are noted but not fixed in this run."
  if [ "$NO_TESTS" = "1" ]; then
    echo "No tests were ordered for this task on purpose: do not ask for tests, test scripts"
    echo "or new dependencies for them, and do not count missing tests as a gap."
  fi
  echo "If a bug is typical for weaker developers, append at most two lines at the end"
  echo "in the format 'RULE: <general, project-independent rule>'."
  echo "If everything is fine, answer only: OK"
} | llm "$REVIEW_MODEL" "You are a code reviewer. Answer directly and concisely." review > "$W/review.md"

# Points outside the task (marked with "OUT-OF-SCOPE:") go to later.md instead of to Qwen:
# otherwise a small ordered change silently turns into a bigger one.
: > "$W/later.md"; : > "$W/review-inscope.md"
awk -v out="$W/later.md" -v keep="$W/review-inscope.md" '
  /^RULE:/ { next }
  /^[0-9]+\. / { ext = ($0 ~ /^[0-9]+\.[ *]*OUT-OF-SCOPE:/) }
  { if (ext) print > out; else print > keep }' "$W/review.md"
NOUT=$(grep -cE '^[0-9]+\. ' "$W/later.md")
NIN=$(grep -cE '^[0-9]+\. ' "$W/review-inscope.md")

NPTS=$NIN
OPEN_NOTE=""
if grep -qx "OK" "$W/review.md" || { [ "$NIN" -eq 0 ] && [ "$NOUT" -gt 0 ]; }; then
  echo "== Review: OK"
else
  grep '^RULE:' "$W/review.md" | sed 's/^RULE: */- /' >> "$RULES"
  mark reviewfix
  echo "== Qwen fixes the review points"
  cp "$W/review-inscope.md" "$W/review-points.md"
  RFIX_BASE=$(git rev-parse HEAD); PRE_RED=$RED
  # From here on a worker failure no longer aborts the run: die_worker goes back to the
  # state before the review fixes (Nov 18: a run with green steps was thrown away after
  # 52 minutes because the worker failed while fixing review points).
  SOFT_FAIL=1
  fix_points "$W/review-points.md" review "Review points"
  RED=0; fix_loop d || RED=1

  # Recheck: a second, cheap look at only the fix diff. Without it, nobody looks at the code
  # after the review fixes, only the check commands. Round 1 may send points back to Qwen
  # once; round 2 only checks that follow-up (Nov 20: Qwen "fixed" a point with comments
  # only, and nobody looked at its second attempt). RECHECK_MODEL=none turns it off.
  RECHECK_MODEL="${RECHECK_MODEL:-sonnet}"
  recheck() {   # recheck <base commit> <points file> <round>
    { echo "Task: $TASK"; echo; echo "These points had to be fixed:"; cat "$2"; echo
      [ "$RED" -eq 1 ] && { echo "WARNING: The checks are red after the fix:"; tail -30 "$W/test.txt"; echo; }
      echo "A weaker developer addressed them with this diff (truncated if too long):"
      git diff "$1" -- . ':(exclude)*.lock' ':(exclude)package-lock.json' | head -c 50000; echo
      echo "Check only two things: Is each point really fixed in the code (a comment that"
      echo "claims it is fixed does not count), and did the fix break anything new? List only"
      echo "that, as a numbered list with file and concrete fix."
      echo "No new wishes and no new review of the rest of the code."
      if [ "$NO_TESTS" = "1" ]; then echo "No tests were ordered on purpose: do not ask for any."; fi
      echo "If everything is fine, answer only: OK"
    } | llm "$RECHECK_MODEL" "You are a code reviewer. Answer directly and concisely." "recheck$3" > "$W/review2-$3.md"
    if ! grep -q '[^[:space:]]' "$W/review2-$3.md"; then return 2; fi
    { echo; echo "## Recheck $3 of the fixes ($RECHECK_MODEL)"; cat "$W/review2-$3.md"; } >> "$W/review.md"
    grep -qx "OK" "$W/review2-$3.md"
  }
  if [ "$RECHECK_MODEL" != "none" ] && [ "$(git rev-parse HEAD)" != "$RFIX_BASE" ]; then
    mark recheck
    echo "== Recheck by $RECHECK_MODEL"
    recheck "$RFIX_BASE" "$W/review-points.md" 1; rc=$?
    cp "$W/review2-1.md" "$W/review2.md" 2>/dev/null
    if [ "$rc" -eq 2 ]; then
      echo "   Recheck failed, skipping it"; RECHECK=failed
    elif [ "$rc" -eq 0 ]; then
      echo "== Recheck: OK"; RECHECK=ok
    else
      echo "== Recheck: Qwen follows up"; RECHECK=points
      R2_BASE=$(git rev-parse HEAD)
      { echo "A recheck of your review fixes found these points. Fix them completely in the"
        echo "code (do not just add comments) and then run '$TESTCMD' until it is green."
        echo "Keep every fix as small as possible. Do not add new features or new tests."
        cat "$W/review2-1.md"; echo; echo "Task: $TASK"; echo; cat "$W/plan-head.md"
      } | wprompt "$W/q6-recheck.md"
      work code "$W/q6-recheck.md" "$W/recheckfix.txt" || die_worker "fixing recheck" "$W/recheckfix.txt"
      commit "Recheck"
      RED=0; fix_loop e || RED=1
      if [ "$(git rev-parse HEAD)" = "$R2_BASE" ]; then
        OPEN_NOTE="Recheck: points still open (Qwen changed nothing), see $W/review.md"; RECHECK=open
      else
        recheck "$R2_BASE" "$W/review2-1.md" 2; rc=$?
        if [ "$rc" -eq 0 ]; then echo "== Recheck 2: OK"; RECHECK=ok2
        elif [ "$rc" -eq 2 ]; then echo "   Recheck failed, skipping it"; RECHECK=points
        else OPEN_NOTE="Recheck: points still open, see $W/review.md"; RECHECK=open; fi
      fi
    fi
  fi
  SOFT_FAIL=0
fi
final_wrapup
