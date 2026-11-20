# qwen-pipeline

Claude Code slash commands that let a **local model (Qwen, served by Strata)** do the
implementation work, while Claude only plans, writes tests and reviews. Most tokens are
spent on the free local model; the paid models only see short, focused prompts.

| Command | What it does |
|---|---|
| `/qwen <task>` | Full pipeline: Opus plans, Sonnet writes tests, Qwen implements step by step, Opus/Sonnet reviews, Qwen fixes the review points. |
| `/qwen-no-tests <task>` | Same, but without tests: only build/linter check and review. |
| `/q <small change>` | Qwen alone, no Claude model involved. Nothing is committed, nothing is checked. |

## How a `/qwen` run works

1. **Context**: file list, manifests and CI workflows; for projects with more than 40 files Qwen also explores read-only.
2. **Plan** (`PLAN_MODEL`, default `opus`): 2 to 8 small steps, a test command (`TEST:`) and a full CI check (`CHECK:`).
3. **Tests first** (`TEST_MODEL`, default `sonnet`; falls back to Qwen).
4. **Implementation**: Qwen implements each step in a fresh session, one commit per step. Large plans get a mid-run review.
5. **Self-review** by Qwen, only if checks are still red (`SELF_REVIEW=auto`).
6. **Final review** (`REVIEW_MODEL`, default `opus`, `sonnet` for small diffs), Qwen fixes the points, then a cheap recheck of the fixes.

Everything happens on a new branch `qwen/<date-time>`. At the end the run prints an
apply command (`git merge --squash`); nothing is merged, committed to your branch or pushed
unless you ask for it. Start a task with `--pr ` (or set `PR=1`) to open a pull request on a green run.

Before starting, the run aborts if:
- there are uncommitted changes,
- the test command is already red (`ALLOW_RED_BASE=1` to override),
- the current branch is detached, an old `qwen/*` branch, has a deleted upstream or is already merged into the default branch (`ALLOW_ANY_BRANCH=1` to override).

## Requirements

- [Claude Code](https://claude.com/claude-code) (`claude` on the `PATH`)
- A local Anthropic-compatible model server, e.g. Strata, by default at `http://127.0.0.1:8080`
- `bash` (Git Bash on Windows), `git`, `node`, `curl`, `timeout` (coreutils)
- Optional: `gh` for pull requests, `docker` if the project has a Dockerfile

## Installation

```bash
git clone <this repo> && cd qwen-pipeline
./install.sh
```

`install.sh` copies `bin/*` to `~/.claude/bin/` and `commands/*.md` to `~/.claude/commands/`.
Existing files with the same name are backed up as `*.bak-<date>` first.

Configure the local server in `~/.claude/strata.env` (see `strata.env.example`):

```
STRATA_URL=http://127.0.0.1:8080
STRATA_KEY=strata-local
STRATA_MODEL=qwen3.8-flash-next-iq3_xxs
```

The worker runs with its own Claude Code config directory `~/.claude-worker`, so your
normal settings, hooks and MCP servers do not apply to it.

## Files

| File | Purpose |
|---|---|
| `bin/qwen-first.sh` | The pipeline behind `/qwen` and `/qwen-no-tests` |
| `bin/qwen-small.sh` | Behind `/q` |
| `bin/local-worker.sh` | Runs Claude Code headless against the local model |
| `bin/qwen-progress.sh` | Turns the run log into chat updates (for the Monitor tool) |
| `bin/worker-stream.js` | Records the worker's tool use for progress updates |
| `bin/usage-log.js` | Logs tokens and cost per Claude call to `.worker/usage.log` |
| `bin/run-log.js` | One line per run in `~/.claude/qwen-runs.jsonl`; `node ~/.claude/bin/run-log.js show` |

Per-project working files go to `.worker/` (excluded via `.git/info/exclude`, never committed).
Review rules learned across runs are collected in `~/.claude/worker-lessons.md`.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `PLAN_MODEL` / `REVIEW_MODEL` | `opus` | Planner and final reviewer |
| `TEST_MODEL` | `sonnet` | Writes the tests; `qwen` = local worker |
| `SMALL_REVIEW_MODEL` / `MID_REVIEW_MODEL` / `RECHECK_MODEL` | `sonnet` | Reviews of small diffs, mid-run check, recheck (`none` = off) |
| `MAX_TRIES` | `3` | Fix attempts per red check |
| `NO_TESTS` | `0` | `1` = no tests |
| `SELF_REVIEW` | `auto` | `0` never, `1` always |
| `PARTS` | auto | `1` never split, `2` always split into two parts |
| `SPLIT_LINES` / `STEP_LINES` | `350` / `100` | Size thresholds for splitting |
| `WORKER_TIMEOUT_MIN` | `20` | Time limit per worker session |
| `WORKER_CMD_TIMEOUT_MS` / `WORKER_CMD_MAX_TIMEOUT_MS` | `300000` / `600000` | Limit per worker shell command, so servers or wait loops cannot block a stage |
| `CHECK_TIMEOUT_MIN` | `15` | Limit per test/check run of the pipeline (`0` = no limit) |
| `ALLOW_RED_BASE` / `ALLOW_ANY_BRANCH` | `0` | Override the start checks |
| `QWEN_PROGRESS` | quiet | `full` = report every stage |
