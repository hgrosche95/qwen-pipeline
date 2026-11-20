---
description: Opus creates plan, scaffold and first test run, Qwen finishes, Opus only checks diff and tests
argument-hint: <task as a sentence or paragraph>
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
model: opus
---
User's task: $ARGUMENTS

You are the lead. You take the first steps yourself and then hand over to the local Qwen worker.
Work in the current project folder. Do not commit, do not push, do not create a branch.

## 1 Preparation
- If the folder is not a git repository: `git init -q && git add -A && git commit -q --allow-empty -m "Initial state"`.
- If there are uncommitted changes, stop and ask the user to commit or stash first.
- Remember `git rev-parse --short HEAD` as the base.

## 2 Opus: plan, scaffold, first test run
- Read only what you need for the task. Write a short plan (at most 12 lines).
- Create the scaffold: files, signatures, data model, and the tests that check the goal.
  The implementation does not have to be finished, that is Qwen's part.
- Define a test command that exits with 0 on success and run it once, shortened:
  `timeout 15m <test command> > /tmp/qh-test.txt 2>&1; echo "Exit $?"; tail -30 /tmp/qh-test.txt`
  Red tests are expected here. If the command does not run at all (missing tool, syntax error
  in the scaffold), fix that yourself first. The test command must not start servers or
  end-to-end tests.
- Stage your scaffold without committing: `git add -A`. From now on `git diff` only shows
  what Qwen changes afterwards.

## 3 Write the handoff
Write `~/.claude/state/handoff.md` (overwrite) in exactly this format:

```
# Handoff to Qwen
Project: <absolute path>
Base: <base commit>
## Goal
<the task in 1 to 3 sentences>
## Done steps
- <what Opus created, one line per file>
## Open points
1. <concrete, with file and function; what exactly is still missing or red>
## Test command
<one command>
## Rules
- Do not change the tests, unless a test is clearly wrong; then explain why.
- Stick to the open points, no extensions.
- Run the test command until it is green.
- Do not start servers, containers or end-to-end tests and do not write wait loops.
```

Copy it for the worker: `cp ~/.claude/state/handoff.md ~/.claude/state/handoff-task.md`

## 4 Qwen finishes
Start in the project folder as a background process (run_in_background) and wait for it to
end, without checking in between:

WORKER_GUARD=1 bash ~/.claude/bin/local-worker.sh code ~/.claude/state/handoff-task.md > ~/.claude/state/handoff-worker.txt 2>&1

Tell the user in one sentence that Qwen has taken over. If the run ends with
"API Error", "WORKER-TIMEOUT" or "Reached max turns", report that and restart at most
once with the same command; the worker then sees with git diff what is already done.

## 5 Opus only checks diff and tests
Do not read the whole code, only:
- `cat ~/.claude/state/handoff-worker.txt | tail -20`
- `git add -N . && git diff --stat && git diff -- . ':(exclude)*.lock' ':(exclude)package-lock.json' | head -c 40000`
- the test command, shortened as in step 2
- `grep -F "[guard]" ~/.claude/state/handoff-task.log`

Check the diff against the goal and open points. If you find real bugs, write them as new
"Open points" into handoff.md, copy it to handoff-task.md again and hand it back to Qwen at
most once (step 4). Small bugs (a few lines) you fix directly yourself.

At the end, add a section `## Result` to handoff.md (test result, review findings, guard line).

## 6 Wrap-up
At most 10 lines: what is built, tests green or red, what you found in the diff and whether
it is fixed, the guard line. The changes are in the working folder, unstaged/staged, without a
commit. Only commit or push if the user explicitly says so.
