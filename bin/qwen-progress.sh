#!/usr/bin/env bash
# Usage: qwen-progress.sh [log file]
# Narrates a qwen-first.sh run (or a queue of runs) in finished sentences: exactly one update
# per stage change, in the right order (first what finished, then what is running now), with
# details from .worker/ and git. If a stage takes longer, an update about what the worker is
# currently working on comes every few minutes.
# Meant as the command for the Monitor tool: the /qwen command passes on every update exactly
# as written here. Only reads, changes nothing about the run.
# The state is kept in qwen-progress.pos, so a restarted observer (Monitor runs for at most
# 30 minutes) continues seamlessly and reports nothing twice.
LOG="${1:-$HOME/.claude/qwen-run.log}"
POS="$HOME/.claude/qwen-progress.pos"
W=".worker"
if [ ! -d "$W" ] && [ -s "$HOME/.claude/qwen-run.dir" ]; then
  cd "$(cat "$HOME/.claude/qwen-run.dir")" 2>/dev/null || true
fi
PAT='^== |Out of scope|^ABORT|^WARNING|^Plan does not|Full check|Tests red|steps, test command|Worker |Exploration failed|Self-review failed|Test model |Review part |Recheck failed|Size: |Mid-run check failed|Intermediate state stays red'
# Activity updates: at the earliest this many seconds after the last update
ACT_EVERY=240
# Quiet (default): only updates you react to - plan, red, time limit, review points,
# abort, done, task change in a queue. Every update costs the accompanying chat one turn with
# the whole history. QWEN_PROGRESS=full reports every stage again.
QUIET=1; [ "${QWEN_PROGRESS:-}" = "full" ] && QUIET=0
# Routine stages that report nothing in quiet mode. Everything else (including unknown) passes.
routine() {
  case "$1" in
    "== 1/6"*|"== 2/6"*|"== 3/6"*|"== 4/6"*|"== 5/6"*|"== 6/6"*|"== Review: OK"*|*"Review part "*|\
    "== Recheck by"*|"== Recheck: OK"*|*"Full check running"*) return 0 ;;
  esac
  return 1
}

# n: reported log lines, seen: reported commit, checking: full check running,
# late: self-review has started, actn: reported lines of the worker transcript
{ read -r n seen checking late actn < "$POS"; } 2>/dev/null
case "$n" in ''|*[!0-9]*) n=0 ;; esac
case "$actn" in ''|*[!0-9]*) actn=0 ;; esac
[ "$seen" = "-" ] && seen=""
[ "$checking" = "1" ] || checking=0
[ "$late" = "1" ] || late=0

# An update is collected first and then printed in one piece, so it arrives as one message
# and not in parts that overtake each other.
out=""; live=1; red=0
say() { out="${out}${out:+$'\n'}$*"; }

# What the last commit of the run did, if not reported yet. Returns 1: nothing new.
commit_note() {
  local h s what stat files more
  # When catching up on older lines (late start), the current commit does not match the line:
  # only the newest line of a round may talk about git.
  [ "$live" = "1" ] || return 0
  h=$(git rev-parse --short HEAD 2>/dev/null) || return 1
  [ "$h" = "$seen" ] && return 1
  s=$(git log -1 --format=%s 2>/dev/null)
  case "$s" in qwen:*) s=${s#qwen: } ;; *) return 1 ;; esac
  seen=$h
  case "$s" in
    Tests)                what="The tests are written" ;;
    "Step "*)             what="$s is implemented" ;;
    Fix*)                 what="The fix is in" ;;
    "Hint applied")       what="The planner's hint is applied" ;;
    Self-review)          what="Qwen followed up after the self-review" ;;
    "Review points")      what="The review points are fixed" ;;
    "Review points "*)    what="Review part ${s#Review points } is fixed" ;;
    Recheck)              what="The points from the recheck are fixed" ;;
    "Mid-run review")     what="The points of the mid-run check are fixed" ;;
    "Mid-run review "*)   what="Part ${s#Mid-run review } of the mid-run check is fixed" ;;
    *)                    what="$s" ;;
  esac
  stat=$(git show --numstat --format= HEAD 2>/dev/null |
    awk 'NF>=3{a+=$1;d+=$2;c++} END{if(c) printf "%d file%s, +%d/-%d", c, (c==1?"":"s"), a, d}')
  files=$(git show --name-only --format= HEAD 2>/dev/null | grep -v '^$' | head -4 | sed 's|.*/||' | paste -sd, - | sed 's/,/, /g')
  more=$(( $(git show --name-only --format= HEAD 2>/dev/null | grep -vc '^$') - 4 ))
  [ "$more" -gt 0 ] && files="$files and $more more"
  say "$what: $files ($stat)."
  return 0
}

# State of the last check: summary of the test run and the first red tests
tests_note() {
  [ -s "$W/test.txt" ] || return
  local sum failed
  [ "$live" = "1" ] || return
  sum=$(grep -oE '[0-9]+ (passed|failed)[^=]*' "$W/test.txt" | tail -1 | sed 's/ *$//')
  # In the full check a green test run can come before a red linter: then the test line says
  # nothing about the failure, and the last output lines are more honest.
  case "$sum" in *failed*) ;; *) [ "$checking" = "1" ] && sum="" ;; esac
  if [ -n "$sum" ]; then
    say "Test status: $sum."
    failed=$(grep -E '^(FAILED|ERROR) ' "$W/test.txt" | head -4 | sed 's/ - .*//' | cut -c1-140 | sed 's/^/  /')
    [ -n "$failed" ] && say "$failed"
  else
    say "Last output: $(grep -v '^ *$' "$W/test.txt" | tail -2 | cut -c1-160 | paste -sd'|' - | sed 's/|/ | /')"
  fi
}

step_title() { grep '^## Step ' "$W/plan.md" 2>/dev/null | sed -n "${1}p" | sed 's/^## Step [0-9]*: *//'; }

# What the worker has been working on since the last update (from the local-worker.sh
# transcript): edited files, otherwise read ones, and the last command.
activity_note() {
  local f="$W/activity.log" total new edits reads cmd msg
  [ -s "$f" ] || return 1
  total=$(wc -l < "$f" | tr -d ' ')
  [ "$total" -lt "$actn" ] && actn=0
  [ "$total" -gt "$actn" ] || return 1
  new=$(sed -n "$((actn+1)),${total}p" "$f")
  actn=$total
  edits=$(printf '%s\n' "$new" | awk -F'\t' '$2=="Edit"||$2=="Write"||$2=="MultiEdit"{f=$3; sub(/.*[\\\/]/,"",f); if(f!="" && !s[f]++ && c<4){o=o (o?", ":"") f; c++}} END{print o}')
  reads=$(printf '%s\n' "$new" | awk -F'\t' '$2=="Read"{f=$3; sub(/.*[\\\/]/,"",f); if(f!="" && !s[f]++ && c<3){o=o (o?", ":"") f; c++}} END{print o}')
  cmd=$(printf '%s\n' "$new" | awk -F'\t' '$2=="Bash"{c=$3} END{print c}' | cut -c1-80)
  if [ -n "$edits" ]; then msg="Progress: Qwen is editing $edits"
  elif [ -n "$reads" ]; then msg="Progress: Qwen is reading $reads"
  else msg="Progress: Qwen is still working on this stage"; fi
  [ -n "$cmd" ] && msg="$msg; last command: $cmd"
  echo "$msg."
}

model_name() { case "$1" in sonnet) echo Sonnet ;; opus) echo Opus ;; haiku) echo Haiku ;; *) echo "$1" ;; esac; }

event() {
  local l="$1" i total v pts base
  case "$l" in
    "== Task "*)
      v=${l#== Task }; say "Task ${v%%/*} of $(printf '%s' "${v#*/}" | sed 's/:.*//') starts:$(printf '%s' "$v" | sed 's/^[^:]*://')" ;;
    "== Queue halted"*) say "${l#== }." ;;
    "== Queue done"*)
      say "The queue is through: ${l#== Queue done: }."
      say "$(sed -n '/^== Queue done/,$p' "$LOG" 2>/dev/null | tail -n +2 | grep -v '^ *$' | sed 's/^ */  /')" ;;
    "WARNING: Tests are still red"*) red=1 ;;
    "== 1/6"*) late=0; checking=0; red=0; say "The run has started. First the project is explored." ;;
    "== 2/6"*) say "The plan is being written." ;;
    *"steps, test command"*)
      say "The plan is ready:"
      say "$(grep '^## Step ' "$W/plan.md" 2>/dev/null | sed 's/^## Step \([0-9]*\): */  \1. /')"
      say "Checked with: ${l#*test command: }" ;;
    "   Size: "*) say "Estimated size: ${l#   Size: }." ;;
    "== Mid-run check after"*)
      commit_note
      v=$(model_name "${l##* by }")
      say "Part 1 is implemented. Now $v checks the intermediate state." ;;
    "== Mid-run check: OK"*) say "The mid-run check found nothing to fix, continuing with part 2." ;;
    "== Qwen fixes the mid-run check points"*)
      pts=$(grep -cE '^[0-9]+\. ' "$W/review-mid.md" 2>/dev/null)
      say "The mid-run check found ${pts:-some} point(s), Qwen fixes them before part 2:"
      say "$(grep -E '^[0-9]+\. ' "$W/review-mid.md" 2>/dev/null | sed 's/\*\*//g; s/`//g' | head -8 |
        awk '{ if (length($0) > 170) print "  " substr($0, 1, 170) " ..."; else print "  " $0 }')" ;;
    *"Mid-run check failed"*) say "The mid-run check failed, so the final review sees the whole diff instead." ;;
    *"Intermediate state stays red"*) say "The intermediate state stays red, continuing with part 2 anyway." ;;
    *"Worker hit the turn limit"*)
      say "The stage reached the limit of 40 work steps and continues in a fresh session." ;;
    *"Full check running"*)
      commit_note
      checking=1
      if [ "$late" = "1" ]; then
        say "To finish, the full check runs once more."
      else
        say "All steps are implemented. Now the full check runs, like in the CI."
      fi ;;
    *"Full check is already red at the starting state"*)
      say "The full check is already red before the change and is skipped for this run." ;;
    *"Full check stays red"*)
      checking=0; say "The full check stays red even after the fixes." ;;
    *"Full check green"*) ;;
    "   Full check: "*)
      say "Later the full check also runs, like in the CI (linters and tests of all subprojects)." ;;
    *"Worker failed, retrying"*)
      say "The local model failed. The stage is repeated once." ;;
    *"Worker hit the time limit"*)
      say "The stage reached the time limit and continues in a fresh session." ;;
    *"Worker still not done after two continuations"*)
      say "The stage is still not done after two continuations." ;;
    *"Exploration failed"*) say "The exploration failed, the plan is written without it." ;;
    *"Self-review failed"*) say "The self-review failed and is skipped." ;;
    "== 3/6 skipped"*) ;;
    "== 3/6"*)
      v=${l#== 3/6 }; v=$(model_name "${v% writes the tests}")
      say "$v writes the tests first." ;;
    *"Test model "*" failed"*) say "The test model failed, Qwen writes the tests." ;;
    "== 4/6"*)
      i=$(printf '%s' "$l" | sed -n 's/.*step \([0-9]*\)\/\([0-9]*\).*/\1/p')
      total=$(printf '%s' "$l" | sed -n 's/.*step \([0-9]*\)\/\([0-9]*\).*/\2/p')
      if ! commit_note && [ "${i:-1}" -gt 1 ]; then say "Step $((i-1)) needed no change of its own."; fi
      say "Now step $i of $total: $(step_title "$i")." ;;
    *"Tests red"*)
      v=${l##*fix attempt }
      commit_note
      if [ "$checking" = "1" ]; then
        say "The full check is red. Qwen is fixing it, attempt ${v%/*} of ${v#*/}."
      else
        say "The tests are red. Qwen is fixing them, attempt ${v%/*} of ${v#*/}."
      fi
      tests_note ;;
    "== Escalation"*)
      commit_note; say "Qwen cannot get the tests green, so the planner now gives a hint." ;;
    "== 5/6 skipped"*)
      commit_note
      if [ "$checking" = "1" ]; then say "The full check passed."; checking=0; else tests_note; fi
      late=1; selfskip=1
      case "$l" in
        *"checks green"*) say "All checks are green, the self-review is skipped." ;;
        *) say "The self-review is turned off and skipped." ;;
      esac ;;
    "== 5/6"*)
      selfskip=0
      commit_note
      if [ "$checking" = "1" ]; then say "The full check passed."; checking=0; else tests_note; fi
      late=1
      say "Now Qwen reads its own diff against the task and plan (self-review)." ;;
    "== 6/6"*)
      commit_note || [ "${selfskip:-0}" = "1" ] || say "The self-review is done."
      v=${l#== 6/6 }; say "Now comes the final review by $(model_name "${v% reviews}")." ;;
    "== Review: OK"*) say "The review found nothing to fix." ;;
    "== Qwen fixes the review points"*)
      pts=$(grep -cE '^[0-9]+\. ' "$W/review.md" 2>/dev/null)
      say "The review found ${pts:-some} point(s), Qwen fixes them:"
      say "$(grep -E '^[0-9]+\. ' "$W/review.md" 2>/dev/null | sed 's/\*\*//g; s/`//g' | head -8 |
        awk '{ if (length($0) > 170) print "  " substr($0, 1, 170) " ..."; else print "  " $0 }')" ;;
    *"Review part "*)
      v=${l##*Review part }
      commit_note
      say "Now review points part ${v%/*} of ${v#*/}." ;;
    "== Recheck by "*)
      commit_note
      v=$(model_name "${l#== Recheck by }")
      say "Now $v rechecks whether the review points are really fixed." ;;
    "== Recheck: OK"*) say "The recheck found nothing to fix." ;;
    "== Recheck: Qwen"*)
      say "The recheck still found points, Qwen follows up:"
      say "$(grep -E '^[0-9]+\. ' "$W/review2.md" 2>/dev/null | sed 's/\*\*//g; s/`//g' | head -6 |
        awk '{ if (length($0) > 170) print "  " substr($0, 1, 170) " ..."; else print "  " $0 }')" ;;
    *"Recheck failed"*) say "The recheck failed and is skipped." ;;
    "== Done"*)
      commit_note
      if [ "$checking" = "1" ]; then say "The full check passed."; checking=0; fi
      # red only applies to this run: "== 1/6" resets it (queue)
      if [ "$red" = "1" ]; then
        say "The run is through, but the check is still red."
      else
        say "The run is done, all checks are green."
      fi
      base=$(grep 'View:' "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*git diff \([0-9a-f]*\) .*/\1/p')
      say "Branch ${l#*branch }$([ -n "$base" ] && git diff --numstat "$base" 2>/dev/null |
        awk 'NF>=3{a+=$1;d+=$2;c++} END{if(c) printf ", in total %d file%s, +%d/-%d", c, (c==1?"":"s"), a, d}')." ;;
    *"Out of scope:"*)
      v=${l#*Out of scope: }; v=${v%%,*}
      say "The review noted $v out of scope. They are not fixed and are listed in .worker/later.md." ;;
    "== Pull request created"*) say "The pull request is created." ;;
    "== No PR"*|"== PR could"*) say "${l#== }." ;;
    ABORT*) say "Aborted: ${l#ABORT: }"; tests_note ;;
    "Plan does not"*) say "Aborted: The plan did not come in the expected format, see .worker/plan.md." ;;
  esac
}

# End of observing: for a queue only with its final line, otherwise with the end of the
# single run (final line "== End", PR line or abort).
finished() {
  if grep -q '^== Task ' "$LOG" 2>/dev/null; then
    grep -q '^== Queue done' "$LOG" 2>/dev/null
  else
    grep -qE '^== (End$|No PR|Pull request created|PR could not)|^ABORT|^Plan does not' "$LOG" 2>/dev/null
  fi
}

quiet=0; last_msg=$(date +%s)
while true; do
  t=$(wc -l < "$LOG" 2>/dev/null | tr -d ' '); t=${t:-0}
  # Log shorter than remembered: a new run has overwritten it
  [ "$t" -lt "$n" ] && { n=0; seen=""; checking=0; late=0; actn=0; }
  if [ "$t" -gt "$n" ]; then
    out=""
    mapfile -t batch < <(sed -n "$((n+1)),${t}p" "$LOG" | grep -E "$PAT")
    for k in "${!batch[@]}"; do
      live=0; [ "$k" -eq $(( ${#batch[@]} - 1 )) ] && live=1
      o0=$out
      # event always runs (it keeps the state), in quiet mode only the text is dropped
      event "${batch[$k]}"
      [ "$QUIET" = "1" ] && routine "${batch[$k]}" && out=$o0
    done
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      # What the worker has done up to here is covered by this update: do not report it again
      last_msg=$(date +%s)
      [ -f "$W/activity.log" ] && actn=$(wc -l < "$W/activity.log" | tr -d ' ')
    fi
    n=$t; quiet=0
  else
    quiet=$((quiet+1))
    if [ "$QUIET" = "0" ] && [ $(( $(date +%s) - last_msg )) -ge "$ACT_EVERY" ] && activity_note; then
      last_msg=$(date +%s); quiet=0
    fi
    # 400 x 3 s = 20 minutes without any sign of life: report it, so silence does not look like progress
    [ "$quiet" -eq 400 ] && echo "There has been no sign of life from this stage for 20 minutes."
  fi
  echo "$n ${seen:--} $checking $late $actn" > "$POS"
  finished && break
  sleep 3
done
