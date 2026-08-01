# nightlight

Leave a light on while you sleep. Runs unattended Claude Code sessions against a repo's `TASKS.md`, opens the work as reviewable PRs, never touches `main` directly.

This repo holds the runner and its config — nothing else. No dependencies, no dashboard, no daemon watching your usage window. It never copies anything into the repos it works on either — it reaches into them with `--add-dir` for the duration of one session and leaves nothing behind. Point it at any repo with a `TASKS.md` and it works the same way, which is what makes it portable rather than tied to one project.

## How it works

- `overnight.sh` points at a target repo, checks it has a `TASKS.md`, and launches `claude -p` with `--add-dir <target-repo>`.
- Because the session is launched from *this* repo, its `CLAUDE.md` (the workflow rules), `.claude/settings.json` (the permission allowlist), and `.claude/commands/` (the `/plan-tasks` command) all apply — regardless of which repo got added.
- The target repo's own `CLAUDE.md` stays exactly what it'd be without this system: test command, code conventions. No overnight-specific content ever gets written into it.
- The agent works entirely on `overnight/<date>/*` branches, opens a PR per task, and a single housekeeping PR at the end updates `TASKS.md` and the archive. Nothing else touches those two things.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI, logged in.
- [pnpm](https://pnpm.io) — used only as a task runner here (`pnpm plan`, `pnpm overnight`), no actual dependencies to install.
- Git, GitHub CLI (`gh`) authenticated for the target repo.
- [`jq`](https://jqlang.org) — formats the live session output (see Usage below).
- A target repo with a `TASKS.md` at its root (see format below) and a `CLAUDE.md` with your test command and conventions.

## Configuration

Repo location is set once, in a gitignored `.env` at the root:

```bash
# .env — not committed, machine-specific
PROJECT_REPOS_DIR=/Users/you/Documents/project-repos
```

Both `overnight.sh` and `plan.sh` source this, so the path only lives in one place. Copy `.env.example` to `.env` and edit it after cloning; `.env` itself is gitignored alongside `logs/`.

This `.env` only ever holds `PROJECT_REPOS_DIR` — a path, not a secret — and gets sourced by the shell scripts before `claude` ever launches, so it's unrelated to the `Read(.env)` / `Read(.env.*)` deny rule in `.claude/settings.json`. That rule stops the *agent* from reading `.env` files inside whatever target repo it's working in, which may hold real credentials.

**Why not Claude Code's own `additionalDirectories` setting instead?** It exists (`.claude/settings.json` or the gitignored `.claude/settings.local.json`) and is the persisted equivalent of `--add-dir` — no CLI flag needed, ever. But it only accepts static paths, and pointing it at the whole `project-repos` folder grants every session access to every repo under it, not just the one you're working on. That's a real convenience if you don't mind the blanket access. This repo defaults to the narrower option instead: a wrapper script that resolves one repo name to one path per session, staying consistent with how `overnight.sh` already scopes each run to a single target.

## Setup

1. Clone this repo somewhere permanent.
2. Copy `.env.example` to `.env` and set `PROJECT_REPOS_DIR`.
3. Edit `CLAUDE.md` here if you want to change the workflow rules (branching scheme, quality gates, how research tasks work, etc.) — the defaults are a reasonable starting point.
4. Edit `.claude/settings.json` to match your actual test/lint/build commands (defaults assume npm/pnpm).
5. In each target repo, add a `TASKS.md` with your work queue and confirm `CLAUDE.md` has a test command and conventions documented. That's the only setup required in the target repo itself.
6. `chmod +x overnight.sh plan.sh`. No `pnpm install` needed — `package.json` has no dependencies, it's just script aliases.

## plan.sh

Wrapper for interactive planning sessions, so `/plan-tasks` runs against the right repo with zero manual steps:

```bash
#!/bin/bash
set -e
source "$(dirname "$0")/.env"
REPO="${1:?usage: plan.sh <repo>}"
TARGET="$PROJECT_REPOS_DIR/$REPO"
[[ -d "$TARGET" ]] || { echo "not found: $TARGET"; exit 1; }
exec claude --add-dir "$TARGET" "/plan-tasks"
```

```bash
./plan.sh some-repo
```

This adds the target repo *and* submits `/plan-tasks` as the session's first message in one command — `claude "<prompt>"` (no `-p`) starts a normal interactive session with that message pre-submitted, then stays interactive, so you still get the full back-and-forth: the proposal comes back, you review it, and only after you approve does it write to `TASKS.md`. Nothing about the approval step changes, you just skip typing the path and the command by hand.

Or via the `package.json` script (see Scripts below): `pnpm plan some-repo`.

## .claude/commands/plan-tasks.md

The `/plan-tasks` command does the task breakdown that makes the overnight run actually work — `overnight.sh` executes a queue, it doesn't design one. Run this before every session, any time `TASKS.md` has new or vague items in it.

```markdown
Read TASKS.md and CLAUDE.md. For each unchecked Agent-Ready item:
1. Investigate the relevant parts of the codebase.
2. Propose a sub-task breakdown with file-level hints and any missing acceptance criteria.
3. Flag missing prerequisites (fixtures, env vars, dependencies) as NEEDS HUMAN annotations.
4. Analyze dependencies AND shared-file overlap between tasks (schemas, barrel exports,
   shared components), then propose a [stack: <name>] annotation for every task: tasks
   that depend on each other or touch the same files share a stack name in execution
   order; genuinely independent tasks get [stack: solo]. When in doubt, stack.
Present the full proposal for my approval BEFORE writing anything. After approval, write
the breakdowns and [stack] annotations into TASKS.md. Do not implement anything.
```

It matters for two reasons:

- **Acceptance criteria and file-level hints.** A raw task like "add rate limiting" is too vague to run unattended safely — this turns it into something with a defined "done."
- **`[stack: <name>]` assignment.** This is what makes the overnight PRs mergeable in the right order. It's driven by real dependency and shared-file analysis (schemas, barrel exports, shared components), not guessed at — and it's deliberately biased toward stacking ("when in doubt, stack") over declaring things independent, since a false `solo` risks two PRs conflicting on the same file with no ordering to resolve it.

Runs interactively, proposes before writing anything, and never implements — it only edits `TASKS.md`. `plan.sh` (below) launches it directly.

## Scripts

```bash
pnpm plan some-repo       # ./plan.sh some-repo
pnpm overnight some-repo  # ./overnight.sh some-repo
```

Thin `package.json` wrappers around the two shell scripts — no dependencies, nothing to `pnpm install`. Args pass straight through to the script (pnpm doesn't need a `--` separator the way npm does), so `pnpm plan some-repo` and `./plan.sh some-repo` are identical. Use whichever reads better; the rest of this README uses the raw `./script.sh` form since it's unambiguous about what's actually running.

## Usage

```bash
# breakdown first (see plan.sh above) if TASKS.md has anything new or vague
./plan.sh some-repo

# the actual overnight run
./overnight.sh some-repo
```

`overnight.sh` resolves a bare name against `$PROJECT_REPOS_DIR` (from `.env`) or accepts a full path. Run it inside `tmux` or a terminal window you can leave open — closing the window kills the process. Disable sleep/hibernate for the duration.

Only run one repo at a time per machine (shared usage pool). Chain sequentially if you need more than one: `./overnight.sh repo-a && ./overnight.sh repo-b`.

`overnight.sh` runs `claude -p` with `--output-format stream-json`, so the session's events (assistant text, tool calls, tool results) arrive incrementally rather than all at once at the end. Each line is piped through `format-stream.jq`, so the terminal you launched `overnight.sh` from shows clean, readable progress live — no separate `tail -f` needed. The agent opens one PR per task as it finishes, so a `gh pr create` call showing up in that live output is your signal that task is done and ready to check, rather than waiting for the whole run to finish.

Three files land in `logs/`, all gitignored: `<repo>-<date>.jsonl` (the raw NDJSON event stream, unformatted, kept for later inspection or tooling), `<repo>-<date>.log` (the same `format-stream.jq` output shown live in your terminal, saved as-is), and `<repo>-<date>.stderr.log` (anything the `claude` process wrote to stderr, kept separate so it doesn't break the JSON stream).

Switching to `stream-json` only changes how the CLI reports events to us locally — it doesn't change what the agent does or what it costs. The final `result` event includes `total_cost_usd` for the whole session, which `format-stream.jq` prints as the closing summary line.

## Behavior notes

- **The session doesn't pause between tasks.** The prompt (`overnight.sh`) tells the agent to work through every Agent-Ready, Verify, and Research item in one continuous run, stopping only once everything is complete, annotated `NEEDS HUMAN`, or annotated `blocked` — not after each task.
- **Within a stack, later tasks don't wait for earlier ones to be reviewed.** Each task branches from the previous task's branch tip, so task 2 builds on task 1's code as soon as it's written, regardless of whether you've looked at task 1's PR yet. A `NEEDS HUMAN` annotation on task 1 (missing env var, API key, etc.) doesn't pause the stack — the code is presumed complete, just not fully runnable without that step.
- **`blocked` is for cross-stack dependencies, not same-stack ordering.** It only gets used when a task turns out mid-implementation to depend on work in a *different* stack. If a task's correctness genuinely depends on the real-world outcome of an earlier same-stack task's human-verification step (not just on that task's code existing), there's no automatic rule catching that today — it falls to the agent's judgment under the general "ambiguous, annotate why, skip it" rule.

## TASKS.md format (in the target repo)

```markdown
## Agent-Ready
- [ ] [stack: auth] Add rate limiting to login endpoint
      Acceptance: 5 failed attempts locks for 15 min, test covers it

## Verify (may already be done)
- [ ] Confirm CSRF protection is enabled on all POST routes

## Research
- [ ] Compare Postgres full-text search vs. a dedicated search service
      Output: docs/research/search-options.md

## Decisions (human only)
- [ ] Pick a payment provider

## Discovered
<!-- agent appends here during a session; you triage each morning -->
```

- **Agent-Ready** — implemented in file order, each with acceptance criteria.
- **Verify** — confirmed or implemented, whichever the codebase needs.
- **Research** — produces a markdown doc, never touches code.
- **Decisions (human only)** — never attempted by the agent.
- **`[stack: <name>]`** — tasks sharing a stack name are branched and PR'd in sequence (each targets the previous branch); tasks with no annotation are treated as continuing the previous task's stack. Assign these during `/plan-tasks`, not by hand.

## What you get in the morning

- One PR per task, each targeting either `main` or the previous branch in its stack.
- One `chore: session housekeeping <date>` PR that updates `TASKS.md` and adds `docs/tasks-archive/<date>.md` — the only PR that touches either.
- Anything the agent couldn't finish is annotated `NEEDS HUMAN: <steps>` (env vars, API keys, dashboard config) or `blocked: <reason>` (judgment calls, missing context) directly in `TASKS.md`, and in the relevant PR description.

Merge stacks bottom-up. Merge solos and housekeeping whenever.

## Safety model

No `--dangerously-skip-permissions`. `.claude/settings.json` is an explicit allowlist (test/lint/build commands, safe git operations, PR creation) plus an explicit denylist (`main`/`master` push, merge, `rm -rf`, `.env` reads, `--no-verify`). The agent can't merge its own work or push to a protected branch — everything it produces is a PR waiting for you to look at it. If a task needs judgment or credentials it doesn't have, it's supposed to stop and annotate rather than guess.

## Prior art

This isn't the only take on "run Claude Code overnight." A few others, for comparison:

- [night-shift](https://github.com/ppuliu/night-shift) — Claude and Codex adversarially review each other's work so no single model grades its own homework. Runs with `--dangerously-skip-permissions`.
- [ClaudeNightsWatch](https://github.com/aniketkarne/ClaudeNightsWatch) — a daemon that fires a task file right before your usage window resets, rather than a manual trigger.
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — a literal loop: PR, wait for checks, merge, repeat.
- [Boucle](https://github.com/Bande-a-Bonnot/Boucle-framework) — cron-scheduled, with its own persistent-memory layer across runs.

The main difference here: this system never bypasses permissions and never merges its own PRs. Everything above defaults to skipping permission prompts for the autonomous run; this one trades some autonomy for an explicit allowlist and human-reviewed merges instead.
