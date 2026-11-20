# qwen-pipeline

Claude Code slash commands that let a **local model (Qwen, served by Strata)** do the
implementation work, while Claude only plans, writes tests and reviews. Most tokens are
spent on the free local model; the paid models only see short, focused prompts.

| Command | What it does |
|---|---|
| `/qwen <task>` | Full pipeline: Opus plans, Sonnet writes tests, Qwen implements step by step, Opus/Sonnet reviews, Qwen fixes the review points. |
| `/qwen-no-tests <task>` | Same, but without tests: only build/linter check and review. |
| `/q <small change>` | Qwen alone, no Claude model involved. Nothing is committed, nothing is checked. |
| `/qwen-guard <task>` | Like `/qwen`, but the worker runs with a guard hook (dangerous commands, secret files, repeats), a 30-minute limit and shortened test output. |
| `/qwen-queue [file]` | Several tasks one after another from `.worker/queue.txt`, each building on the previous one. |
| `/qhandoff <task>` | Opus writes plan, scaffold and tests itself, Qwen finishes, Opus only checks diff and tests. |

## How a `/qwen` run works

1. **Context**: file list, manifests and CI workflows; for projects with more than 40 files Qwen also explores read-only.
2. **Plan** (`PLAN_MODEL`, default `opus`): 2 to 8 small steps, a test command (`TEST:`) and a full CI check (`CHECK:`).
3. **Tests first** (`TEST_MODEL`, default `sonnet`; falls back to Qwen). The test model also
   reports where the code contradicts the plan (`PLAN-DEVIATIONS:`); these facts go into every
   later prompt for Qwen and the reviewers, because the planner never sees the code.
4. **Implementation**: Qwen implements each step in a fresh session, one commit per step. Large plans get a mid-run review.
5. **Self-review** by Qwen, only if checks are still red (`SELF_REVIEW=auto`).
6. **Final review** (`REVIEW_MODEL`, default `opus`, `sonnet` for small diffs), Qwen fixes the points,
   then a cheap recheck of the fixes. If the recheck still finds points, Qwen gets one more round
   and a second recheck verifies it; whatever is still open is reported as open, not as fixed.
   If the worker fails while fixing review points, the run falls back to the green state before
   the review fixes (partial work on `<branch>-partial`) and finishes with the points marked open.

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
normal settings, hooks and MCP servers do not apply to it. Auto memory is turned off for the
worker (`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`): notes from earlier sessions made it repeat stale
plans and start end-to-end tests with servers.

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
| `bin/qwen-queue.sh` | Behind `/qwen-queue` |
| `bin/worker-guard.js` | PreToolUse hook for the worker with `WORKER_GUARD=1` (log: `~/.claude/logs/worker-guard.log`, `GUARD_MODE=block` to deny) |
| `bin/test-wrap.sh` | Used by the guard: full test output to `~/.claude/logs/tests/`, only the essentials to the model |

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
| `TEST_TURNS` | `12` | Turn limit of the test model (each turn re-reads the history, the biggest cost item) |
| `SPLIT_LINES` / `STEP_LINES` | `350` / `60` | Size thresholds for splitting |
| `WORKER_TIMEOUT_MIN` | `20` (`30` with guard) | Time limit per worker session |
| `WORKER_GUARD` / `GUARD_MODE` | `0` / `log` | Guard hook on; `block` denies dangerous calls instead of logging them |
| `WORKER_CMD_TIMEOUT_MS` / `WORKER_CMD_MAX_TIMEOUT_MS` | `300000` / `600000` | Limit per worker shell command, so servers or wait loops cannot block a stage |
| `CHECK_TIMEOUT_MIN` | `15` | Limit per test/check run of the pipeline (`0` = no limit) |
| `ALLOW_RED_BASE` / `ALLOW_ANY_BRANCH` | `0` | Override the start checks |
| `QWEN_PROGRESS` | quiet | `full` = report every stage |

## License

MIT, see [LICENSE](LICENSE).
