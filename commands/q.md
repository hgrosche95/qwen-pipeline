---
description: Have the local Qwen implement a small change on its own (without Opus)
argument-hint: <small change in one sentence>
allowed-tools: Bash
model: haiku
---
User's task: $ARGUMENTS

Immediately, without reading files or analyzing the task, start this command in the current
project folder as a background process (run_in_background). Pass the task text unchanged
as a single argument in quotes:

bash ~/.claude/bin/qwen-small.sh "<task>"

Say in one sentence that Qwen is working. Do not check the status in between.
When the process ends, summarize its output in at most 6 lines: what Qwen did,
test result, changed files. Do not read the diff, do not check anything and do not change anything.
