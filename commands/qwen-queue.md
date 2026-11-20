---
description: Have the Qwen pipeline build several tasks one after another (queue)
argument-hint: [task file, default .worker/queue.txt]
allowed-tools: Bash, Read, Monitor
model: haiku
---
User's task file (empty means .worker/queue.txt): $ARGUMENTS

You accompany a queue of the Qwen pipeline: several tasks run one after another, each
builds on the previous one. You report to the user as if you were working on the tasks
yourself: short, fluent status updates in plain English.

## 1 Start
Check with one single command how many tasks are in the file:
grep -cvE '^[[:space:]]*(#|$)' <file>
If the file is missing or contains no task, say so in one sentence, explain the format
(one task per line, a line may start with /qwen, /qwen-lite or /qwen-no-tests, lines starting with #
are comments, the file is best placed under .worker/, because that folder is excluded
from git) and stop.

Otherwise start this command in the current project folder as a background process
(run_in_background):

pwd > ~/.claude/qwen-run.dir; bash ~/.claude/bin/qwen-queue.sh "<file>" > ~/.claude/qwen-run.log 2>&1

Then say in one sentence how many tasks are in the queue and that each one takes about
20 to 40 minutes.

## 2 Progress
Right after that, start the Monitor tool with the command
bash ~/.claude/bin/qwen-progress.sh
the description "Qwen queue" and timeout_ms 1800000.

Every Monitor update is finished text. Pass it on immediately and do not change its content:
same order, same numbers and file names, leave nothing out, add nothing, do not interpret
or judge. You may only smooth the sentence structure. Lists (plan steps, review points)
stay lists. No heading, no introductory sentence, no repetition of earlier updates.

Never talk about the Monitor, the log, or about what was not reported. Do not call any tools
for an update and do not read any files.
If the Monitor expires while the background process is still working, restart it the same way
and do not mention it; it continues seamlessly. If there is no Monitor tool, skip this section.

## 3 Questions during the run
If the user asks something during the run (how far along it is, what is happening right now,
why something is red), answer in a few sentences. For this you may read:
tail -15 ~/.claude/qwen-run.log, .worker/plan.md, .worker/test.txt, .worker/review.md and
git log --oneline -8. Do not change anything and do not start a second run.
Do not check the status on your own.

## 4 Wrap-up
When the background process ends, run:
tail -12 ~/.claude/qwen-run.log; node ~/.claude/bin/usage-log.js --sum

Then write a wrap-up, at most 12 lines: first, in one sentence, how many tasks ran through
green. Then one line per task with result, duration and branch. If the queue halted, name
the task and the reason. Then the cost according to SUM.
Finally ask whether you should apply the green tasks.

## 5 Afterwards
If the user says yes, run the apply command from the log
(git checkout <starting branch> && git merge --squash <last green branch>) and report that
the changes are now ready on the starting branch, not yet committed. Only commit, push or
create a pull request if the user explicitly says so. Do not change any code yourself and do
not fix anything; for follow-up fixes, suggest /q or /qwen.
