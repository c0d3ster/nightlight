<img align="right" style="float: right; margin: 0 0 16px 24px;" src="docs/NightlightLogo.png" alt="nightlight logo: a glowing green plug-in nightlight" width="260" />

# nightlight

Leave a light on while you sleep. Runs unattended Claude Code sessions against a repo's task list, opens the work as reviewable PRs, never touches `main` directly.

This repo holds the runner and its config, nothing else. No dependencies, no dashboard, no daemon. It reaches into target repos with `--add-dir` for one session and leaves nothing behind, so it works the same on any repo with a task list.

<br clear="right" />

## How it works

- `overnight.sh` dispatches one fresh `claude -p` subprocess per open task (plus one for end-of-run housekeeping) with `--add-dir <target-repo>`. Each task starts with no memory of the others, so cost stays bounded by one task's work.
- Every subprocess launches from *this* repo, so its `CLAUDE.md` (workflow rules), `.claude/settings.json` (permission allowlist), and `.claude/skills/` apply no matter which repo was added. The target's own `CLAUDE.md` is never modified.
- Stacked tasks (same `[stack: <name>]`, other than `solo`) share context through `docs/stack-notes/<stack>.md` in the target repo. Each task appends an entry, and a later task's prompt gets only the latest one. Housekeeping removes the file once the stack's PRs have all merged.
- Each task ends with a `TASK_RESULT: #<n> status=... branch=... pr=...` line. Housekeeping receives these, confirms real state via `git`/`gh`, then opens the one PR that updates the task list, archive, and `docs/nightlight-meta.json`.
- All work lands on `overnight/<date>/*` branches, one PR per task. `CLAUDE.md` has the full workflow rules.

## Requirements

- Bash 4.3+ (namerefs and associative arrays). macOS ships 3.2, so `brew install bash` and put it first on `PATH`.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI, logged in.
- Git and the GitHub CLI (`gh`), authenticated for the target repo.
- [`jq`](https://jqlang.org/download) for the live session output.
- [pnpm](https://pnpm.io), optional. It is only a script alias runner here (see Commands), nothing to install.
- A target repo with a task list (see below) and a `CLAUDE.md` with its test command and conventions.

## Setup

1. Clone this repo somewhere permanent.
2. Copy `.env.example` to `.env` and set `PROJECT_REPOS_DIR` to the folder holding your repos.
3. `chmod +x *.sh`
4. Adjust `CLAUDE.md` (workflow rules) and `.claude/settings.json` (test/lint/build allowlist) if the defaults don't fit.
5. In each target repo, add a task list and make sure its `CLAUDE.md` documents the test command. Nothing else is needed there.

`.env` is gitignored and only holds `PROJECT_REPOS_DIR`, a path rather than a secret. The scripts source it before `claude` launches, so it is unrelated to the `Read(.env)` deny rule, which stops the *agent* from reading `.env` files in the target repo.

Why not Claude Code's `additionalDirectories` setting? It is a standing grant: every session from this repo would have the target repos forever. The wrapper scripts resolve repo paths per invocation instead, scoped to what that run does.

## Commands

Every script has a `pnpm` alias with the same args (no `--` separator needed). Pick whichever reads better.

| Script | pnpm | What it does |
| --- | --- | --- |
| `./nightlight.sh [repo] [--scan] [overnight flags]` | `pnpm nightlight` | discover, plan, then overnight, chained |
| `./discover.sh [repo] [--scan]` | `pnpm discover` | mine memory (and with `--scan`, the codebase) for task candidates |
| `./plan.sh [repo]` | `pnpm plan` | break tasks down, number them, assign stacks |
| `./overnight.sh [repo] [flags]` | `pnpm overnight` | the unattended run |
| `./migrate.sh <repo> --to github\|linear` | `pnpm migrate` | move `TASKS.md` into issues |
| `./tidy.sh <repo> [--labels \| --no-labels]` | `pnpm tidy` | review and close stale GitHub issues |
| `./stats.sh [repo]` | `pnpm stats` | print cost and time totals |

With no repo, `discover.sh`, `plan.sh`, and `overnight.sh` cover every qualifying repo under `PROJECT_REPOS_DIR`. A bare repo name resolves against `PROJECT_REPOS_DIR`; a full path also works.

### Typical flow

```bash
./discover.sh some-repo     # optional: mine memory for task candidates
./plan.sh some-repo         # break down anything new or vague
./overnight.sh some-repo    # the unattended run
./nightlight.sh some-repo   # or all three chained
```

`discover` and `plan` are interactive: a normal session with the slash command pre-submitted, and nothing is written until you approve. Both open a PR and merge it once you've approved the content in that session (see Safety model). `nightlight.sh` adds one thing, a `[y/N]` pause before the overnight step, since that is the only unattended, costly part. Its flags go to whichever phase understands them, and overnight flags pass through unvalidated.

### Running overnight

Run it in `tmux` or a window you can leave open, and disable sleep. **Ctrl+C** stops the wrapper and kills leftover `claude -p` processes for that repo. Closing the window on Windows does not, so the next run refuses to start while a lock or leftover process exists; pass `--force` to take over. Run one repo at a time per machine (shared usage pool), chaining if needed: `./overnight.sh repo-a && ./overnight.sh repo-b`.

Flags scope a run without editing any files. They append to the base prompt, so workflow rules and housekeeping still apply.

```bash
./overnight.sh some-repo --stop-after 27     # through task #27, then stop
./overnight.sh some-repo --limit 3           # dispatch 3 tasks, then stop
./overnight.sh some-repo --stack auth        # only [stack: auth]
./overnight.sh some-repo --extra-instructions "double check the migration is reversible"
./overnight.sh some-repo --force             # kill leftovers, take a stale lock
```

- `--stop-after N` is a task's permanent `#<n>`, not a count or file position. Work still goes top to bottom, so it is a boundary check, not a filter.
- `--limit N` counts dispatched subprocesses, however they finish (done, needs-human, and blocked all count).
- `--stop-after`, `--stack`, `--extra-instructions`, and `--override-prompt` need a single repo. `--limit` and `--force` apply per repo in no-arg mode.
- `--override-prompt "<text>"` skips the dispatch loop and runs one bare session: no task selection, stack notes, or housekeeping. Prefer the flags above.

Live output is formatted by `format-stream.jq`. You get a `=== session started ===` / `=== session done ===` pair per task, and a `gh pr create` call means that task is finished. Logs land in `logs/<repo>/<date>/` (gitignored), named like the branches: `r<R>-<PP>-t<NN>-<slug>.{jsonl,log,stderr.log}`, the same set for housekeeping and override runs, plus `r<R>-run.log` combining everything.

### Behavior notes

- **Five-hour usage block:** on a `rejected` `five_hour` rate-limit event, the run sleeps until its `resetsAt` and retries the same call (max 3 retries). Weekly blocks are treated as normal failures.
- **No pause between tasks:** the run continues until everything is done, `NEEDS HUMAN`, or `blocked`.
- **Stacks don't wait for review:** each task branches from the previous task's tip, and a `NEEDS HUMAN` on an earlier task doesn't pause the stack.
- **`blocked` is for cross-stack dependencies.** If a task depends on the real-world result of an earlier same-stack human step, nothing catches that automatically; it falls to the agent's judgment under the "ambiguous, annotate, skip" rule.

### Stats

After every dispatched subprocess, its `result` event (cost, duration, turns, token usage) is folded into `stats/<repo>.json`: lifetime `total_*` fields plus a `lastSession` rollup with a per-task breakdown. It is also printed at the end of a run. `stats/<repo>-history.jsonl` gets one appended line per run for time series. Everything is gitignored.

`total_cache_read_tokens` is the number to watch: it should grow roughly linearly with work done. The shape is documented in `docs/stats-schema.json`, and `validate_stats_shape()` in `overnight.sh` warns on a mismatch rather than failing the run.

## Skills

`/plan-tasks` does the breakdown that makes the overnight run work: `#<n>` numbering, `[stack: <name>]` assignment (biased toward stacking, since a false `solo` risks conflicting PRs), and acceptance criteria. `/discover-tasks` mines a repo's memory and, with `--scan`, its codebase for candidates. Both investigate in parallel, then ask for approval before writing anything, and both only touch the task list and `docs/nightlight-meta.json`. Their behavior lives in `.claude/skills/<name>/SKILL.md`.

## Task sources

### Local `TASKS.md` (default)

```markdown
## Agent-Ready
- [ ] #48 [stack: auth] Add rate limiting to login endpoint
      Acceptance: 5 failed attempts locks for 15 min, test covers it

## Verify (may already be done)
- [ ] #49 Confirm CSRF protection is enabled on all POST routes

## Research
- [ ] #50 Compare Postgres full-text search vs. a dedicated search service
      Output: docs/research/search-options.md

## Decisions (human only)
- [ ] #51 Pick a payment provider

## Discovered
<!-- agent appends here during a session; you triage each morning -->
```

- **Agent-Ready:** implemented in file order. **Verify:** confirmed or implemented. **Research:** produces a markdown doc, never code. **Decisions:** never attempted.
- **`#<n>`:** a permanent, never-reused number assigned by `/plan-tasks` on every section, tracked in `docs/nightlight-meta.json`'s `nextTaskNumber`. It lets a PR or note reference a task after it's archived.
- **`[stack: <name>]`:** tasks sharing a name are branched and PR'd in sequence. Unannotated tasks inherit the previous task's stack. `solo` is reserved: each solo task branches from and PRs to `main` independently. Assign these in `/plan-tasks`, not by hand.

### GitHub issues (opt-in)

In the target repo's `docs/nightlight-meta.json`:

```json
{
  "taskSource": "github",
  "github": { "repo": "owner/name" },
  "labels": { "agentReady": "nl:agent-ready" }
}
```

An open issue with a section label is a task, and the issue number is the task id. `github.repo` defaults to `origin`. Default labels are `nl:agent-ready`, `nl:verify`, `nl:research`, `nl:blocked`, `nl:needs-human`, `nl:decision`, `nl:discovered` (the last two are never dispatched), and `nl:stack:<name>`. Override keys: `agentReady`, `verify`, `research`, `blocked`, `needsHuman`, `decision`, `discovered`, `stackPrefix`. Housekeeping closes issues once their PR merges and sets the blocked/needs-human labels with a comment. It doesn't write `TASKS.md` or the archive.

**Public repos:** issue text is untrusted input to an agent with write tools. The section label is the gate (applying one needs triage access), and only comments from `OWNER`, `MEMBER`, and `COLLABORATOR` reach the task body. Keep triage access limited to people you trust.

### Linear (opt-in)

```json
{
  "taskSource": "linear",
  "linear": { "teamId": "ENG" }
}
```

`linear.teamId` is a team key or UUID. Tasks are open issues on that team with a section label, with ids like `ENG-142` (so `--stop-after` is unavailable; `--limit` and `--stack` work). **Use one Linear team per repo:** the module scopes only by team and `nl:*` labels, so repos sharing a team would dispatch each other's issues.

One-time setup:

1. **`gh` auth.** Still required for task PRs and merge-state checks. Run `gh auth login`.
2. **API key.** Put `LINEAR_API_KEY=...` in an env file. The target repo's env files are checked first, then nightlight's. Gitignored files go before the rest, in the order `.env.local`, `.env.*.local`, `.env.*`, `.env`. Templates (`.example`, `.sample`, `.template`, `.dist`) are skipped. The first match wins, only that line is read, and a warning prints if the file is tracked or not ignored.
3. **MCP server.** `claude mcp add --scope user --transport http linear https://mcp.linear.app/mcp`, then authenticate via `/mcp`. Confirm with `claude mcp get linear`.

`pnpm migrate <repo> --to linear` (or `github`) moves open `TASKS.md` items into issues, archives checked-off ones, and flips `taskSource` in a small PR. It is interactive: it dedupes against existing issues and merged PRs and asks before creating each one. Re-running after a partial migration is safe, since created issues carry a `Migrated from TASKS.md` marker. `Decisions` and `Discovered` items become `nl:decision` and `nl:discovered` issues.

**Why reads use GraphQL and writes use MCP.** The dispatcher is plain bash, which can't call MCP tools, and listing through a model would cost tokens on every eligibility check. Writes go through MCP because the API key then lives only in bash and never reaches the model or an injected issue body. Permissions also work per operation (allow `save_comment`, deny `delete_comment`), whereas allowing the GraphQL endpoint allows everything. The cost is two credentials and an OAuth session that must stay logged in unattended (seven headless launches kept theirs, see `docs/research/linear-mcp.md`). If OAuth proves flaky, the fallback is a thin wrapper script with fixed operations.

Both modes use an explicit tool allowlist in `.claude/settings.json` (specific `gh issue`/`gh label` commands, specific `mcp__linear__` tools, delete operations denied, no blanket `gh` or MCP allow).

## What you get in the morning

- One PR per task, targeting `main` or the previous branch in its stack.
- One `chore: session housekeeping <date>` PR updating the task list, archive, and `docs/nightlight-meta.json`. It's the only PR that touches them.
- Anything unfinished is annotated `NEEDS HUMAN: <steps>` or `blocked: <reason>` in the task list and the PR description.

Merge stacks bottom-up. Merge solos and housekeeping whenever.

## Safety model

No `--dangerously-skip-permissions`. `.claude/settings.json` is an explicit allowlist (test/lint/build, safe git, PR creation) plus a denylist (push or merge to `main`, `rm -rf`, `.env` reads, `--no-verify`). The agent can't merge its own work. If a task needs judgment or credentials it lacks, it stops and annotates.

**One narrow exception:** `/discover-tasks` and `/plan-tasks` Finalize merge their own PR (`gh pr merge --rebase --delete-branch`). Everything in it was already approved by you in that session, so the merge just completes it. The allowlist only permits `gh pr merge` on `chore/tasks-discover-*` and `chore/tasks-plan-*` branches, which never touch application code, and raw `git merge` stays denied everywhere. Overnight task and housekeeping PRs always wait for you.

## Prior art

- [night-shift](https://github.com/ppuliu/night-shift): Claude and Codex adversarially review each other's work. Uses `--dangerously-skip-permissions`.
- [ClaudeNightsWatch](https://github.com/aniketkarne/ClaudeNightsWatch): a daemon that fires a task file right before your usage window resets.
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude): a loop of PR, wait for checks, merge, repeat.
- [Boucle](https://github.com/Bande-a-Bonnot/Boucle-framework): cron-scheduled, with persistent memory across runs.

The difference here: permissions are never bypassed, and code changes always wait for a human-reviewed merge.
