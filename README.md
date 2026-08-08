# nightlight

Leave a light on while you sleep. Runs unattended Claude Code sessions against a repo's `TASKS.md`, opens the work as reviewable PRs, never touches `main` directly.

This repo holds the runner and its config — nothing else. No dependencies, no dashboard, no daemon watching your usage window. It never copies anything into the repos it works on either — it reaches into them with `--add-dir` for the duration of one session and leaves nothing behind. Point it at any repo with a `TASKS.md` and it works the same way, which is what makes it portable rather than tied to one project.

## How it works

- `overnight.sh` points at a target repo, checks it has a `TASKS.md`, and dispatches one fresh `claude -p` subprocess per open task (plus one more for end-of-run housekeeping) with `--add-dir <target-repo>` — not one continuous session across the whole run. Each task subprocess starts with no memory of any other task, so context (and cache-read cost) stays bounded by one task's own work instead of compounding across every task in the run.
- Because every subprocess is launched from *this* repo, its `CLAUDE.md` (the workflow rules), `.claude/settings.json` (the permission allowlist), and `.claude/skills/plan-tasks/` (the `/plan-tasks` skill) all apply — regardless of which repo got added.
- The target repo's own `CLAUDE.md` stays exactly what it'd be without this system: test command, code conventions. No overnight-specific content ever gets written into it.
- Stacked tasks (sharing a `[stack: <name>]` other than `solo`) still need each other's context. Each stack keeps a `docs/stack-notes/<stack>.md` in the target repo — the first task in a stack creates it, each later one appends its own entry (decisions, interfaces, deviations) — and `overnight.sh` feeds a stacked task's prompt from that file instead of a raw diff or commit dump. Each task subprocess reports back a one-line `TASK_RESULT: #<n> status=... branch=... pr=...`, which `overnight.sh` collects and hands to the housekeeping subprocess as its starting point (housekeeping still confirms real PR/branch state via `git`/`gh` before trusting it).
- The agent works entirely on `overnight/<date>/*` branches, opens a PR per task, and a single housekeeping PR at the end updates `TASKS.md`, the archive, and `docs/nightlight-meta.json`. Nothing else touches those three things.

## Requirements

- Bash 4.3+ (for `local -n` namerefs and `local -A` associative arrays, both used by `overnight.sh`) — the default on Linux and modern Git Bash/WSL; macOS ships 3.2, so install a newer Bash via Homebrew (`brew install bash`) and make sure it's the one on `PATH` before running these scripts.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI, logged in.
- [pnpm](https://pnpm.io) — used only as a task runner here (`pnpm nightlight`, `pnpm plan`, `pnpm overnight`), no actual dependencies to install.
- Git, GitHub CLI (`gh`) authenticated for the target repo.
- [`jq`](https://jqlang.org) — formats the live session output (see Usage below). Install instructions for every platform: [jqlang.org/download](https://jqlang.org/download).
- A target repo with a `TASKS.md` at its root (see format below) and a `CLAUDE.md` with your test command and conventions.

## Configuration

Repo location is set once, in a gitignored `.env` at the root:

```bash
# .env — not committed, machine-specific
PROJECT_REPOS_DIR=/Users/you/Documents/project-repos
```

`overnight.sh`, `plan.sh`, and `discover.sh` all source this, so the path only lives in one place. Copy `.env.example` to `.env` and edit it after cloning; `.env` itself is gitignored alongside `logs/`.

This `.env` only ever holds `PROJECT_REPOS_DIR` — a path, not a secret — and gets sourced by the shell scripts before `claude` ever launches, so it's unrelated to the `Read(.env)` / `Read(.env.*)` deny rule in `.claude/settings.json`. That rule stops the *agent* from reading `.env` files inside whatever target repo it's working in, which may hold real credentials.

**Why not Claude Code's own `additionalDirectories` setting instead?** It exists (`.claude/settings.json` or the gitignored `.claude/settings.local.json`) and is the persisted equivalent of `--add-dir` — no CLI flag needed, ever. But it's a *standing* grant: every session launched from this repo would have it, forever, whether or not that session has anything to do with any target repo. This repo defaults to the narrower option instead: a wrapper script that resolves repo path(s) fresh per invocation, scoped to what that one run is actually doing. `discover.sh`'s no-arg mode (below) does attach the whole `PROJECT_REPOS_DIR` — but only for that one process's lifetime, and only because discover has no filter to narrow it with (see `## discover.sh`); `plan.sh`'s no-arg mode attaches only the repos that actually have work to plan.

## Setup

1. Clone this repo somewhere permanent.
2. Copy `.env.example` to `.env` and set `PROJECT_REPOS_DIR`.
3. Edit `CLAUDE.md` here if you want to change the workflow rules (branching scheme, quality gates, how research tasks work, etc.) — the defaults are a reasonable starting point.
4. Edit `.claude/settings.json` to match your actual test/lint/build commands (defaults assume npm/pnpm).
5. In each target repo, add a `TASKS.md` with your work queue and confirm `CLAUDE.md` has a test command and conventions documented. That's the only setup required in the target repo itself.
6. `chmod +x overnight.sh plan.sh discover.sh nightlight.sh stats.sh`. No `pnpm install` needed — `package.json` has no dependencies, it's just script aliases.

## nightlight.sh

The whole pipeline in one command — chains `discover.sh` → `plan.sh` → `overnight.sh`:

```bash
./nightlight.sh some-repo    # single repo, start to finish
./nightlight.sh              # every repo under PROJECT_REPOS_DIR, start to finish
```

It's a thin orchestrator, not a fourth workflow: each phase is the exact same script described below, run in sequence, with no new approval logic of its own — discover's and plan's own interactive approval gates still apply exactly as if you'd run them by hand. The one thing `nightlight.sh` adds is a pause between planning and execution:

```
Discover and plan are done. Start the overnight run now? [y/N]
```

Discover and plan never write or merge anything without your approval inside those sessions, so chaining them costs nothing extra. `overnight.sh` is different — unattended, potentially hours, real cost — so this is the one point where a chained command should make you deliberately opt in rather than sliding straight into an unattended run. Answering no exits cleanly with a reminder of the equivalent `./overnight.sh` command; nothing is lost, you can run it whenever you're ready.

Every flag is supported and routed to whichever phase actually understands it — `--scan` goes to `discover.sh` only, and `overnight.sh`'s own flags (`--stop-after`, `--limit`, `--stack`, `--extra-instructions`, `--override-prompt`, see `### Limiting a run` below) are forwarded to the `overnight.sh` call verbatim, unvalidated by `nightlight.sh` itself — `overnight.sh` is the one source of truth for what each flag means and requires (e.g. its own single-repo rule for everything but `--limit`):

```bash
./nightlight.sh some-repo --scan --stop-after 27
```

Or via `package.json`: `pnpm nightlight [repo] [--scan] [overnight flags]`.

## discover.sh

Wrapper for `/discover-tasks`, so it runs against the right repo (or repos) with zero manual steps:

```bash
./discover.sh some-repo            # single repo
./discover.sh some-repo --scan     # single repo, plus a codebase scan
./discover.sh                      # every repo under PROJECT_REPOS_DIR
```

Same "adds the target repo and submits the slash command as the first message" shape as `plan.sh` below — a normal interactive session, full back-and-forth, nothing written until you approve. The no-arg form attaches the whole `PROJECT_REPOS_DIR` as one `--add-dir` (discover has no `TASKS.md` prerequisite, so every repo qualifies — see the `additionalDirectories` note above for why that's fine here specifically), then mines every repo's memory in parallel and walks you through approving each repo's candidates one at a time, in order. Each repo's Finalize step now also merges its own PR once you've approved it — see Safety model below.

Or via the `package.json` script (see Scripts below): `pnpm discover [repo] [--scan]`.

## plan.sh

Wrapper for interactive planning sessions, so `/plan-tasks` runs against the right repo (or repos) with zero manual steps:

```bash
./plan.sh some-repo    # single repo
./plan.sh              # every repo under PROJECT_REPOS_DIR with open, unchecked TASKS.md work
```

`claude "<prompt>"` (no `-p`) starts a normal interactive session with `/plan-tasks` pre-submitted as the first message, then stays interactive: the proposal comes back, you review it, and only after you approve does it write to `TASKS.md`. The no-arg form first checks every repo under `PROJECT_REPOS_DIR` for a `TASKS.md` with unchecked items (same check `overnight.sh`'s no-arg mode uses), attaches only the ones that qualify, investigates every repo's items in parallel, then walks you through approving and finalizing each qualifying repo in turn. Each repo's Finalize step now also merges its own PR once you've approved it — see Safety model below.

Or via the `package.json` script (see Scripts below): `pnpm plan [repo]`.

## stats.sh

Local, gitignored cost/time reference — never committed, never touches a target repo. After every dispatched subprocess (each task, plus housekeeping — see How it works above), its `result` event (`total_cost_usd`, `duration_ms`, `num_turns`, and cache token usage) is folded into `stats/<repo>.json` as a running total. `sessions` here counts individual `claude -p` calls, not runs of `overnight.sh`:

```json
{
  "sessions": 13,
  "total_cost_usd": 52.71,
  "total_duration_s": 121430,
  "total_turns": 2870,
  "total_cache_read_tokens": 9482113,
  "total_cache_creation_tokens": 205774,
  "lastSession": {
    "date": "2026-08-01",
    "calls": 3,
    "cost_usd": 6.56,
    "duration_s": 2025,
    "num_turns": 147,
    "cache_read_tokens": 11759541,
    "cache_creation_tokens": 235138,
    "tasks": [
      {"taskNumber": 18, "taskTitle": "Strip sprite background", "status": "done", "cost_usd": 1.30, "duration_s": 445, "num_turns": 28, "cache_read_tokens": 1568035, "cache_creation_tokens": 71886},
      {"taskNumber": 19, "taskTitle": "Some other task", "status": "needs-human", "cost_usd": 4.88, "duration_s": 1449, "num_turns": 104, "cache_read_tokens": 9657573, "cache_creation_tokens": 138775}
    ]
  }
}
```

Two granularities live here:
- `total_*` — lifetime across every `run_repo()` invocation ever, for this repo.
- `lastSession` — every dispatch made by the most recent `overnight.sh` invocation for this repo (every task attempted plus housekeeping), rolled into one number, plus a `tasks` breakdown (one entry per dispatched task, housekeeping excluded) so you can see which task cost what and how it finished at a glance. This is "what did last night's run actually cost me" — printed to stdout at the end of the run too, so you don't need to open this file or dig through logs just to see it. (There's deliberately no per-dispatch `lastRun` here: with one subprocess per task, the last dispatch of a normal run is always housekeeping, whose prompt barely varies call to call, so that number in isolation isn't informative.)

`pnpm stats some-repo` prints that repo's running totals. `pnpm stats` (no arg) sums the `total_*` fields across every `stats/*.json` file, for a comprehensive total across every repo worked from this nightlight instance. It's a snapshot, not a log — each run overwrites the file with updated totals, so there's nothing to grep through, just current numbers. `total_cache_read_tokens` is the one to watch when judging whether the per-task dispatch model (see How it works above) is actually keeping cost down: it should grow roughly linearly with work done, not compound the way a single continuous session across many tasks does.

## .claude/skills/plan-tasks/SKILL.md and .claude/skills/discover-tasks/SKILL.md

`/plan-tasks` does the task breakdown that makes the overnight run actually work — `overnight.sh` executes a queue, it doesn't design one. `/discover-tasks` mines a repo's own memory (and, with `--scan`, its codebase) for task candidates before that. The full, current behavior of each lives in its `SKILL.md` (not reproduced here — this file drifted out of sync with the skills once before and isn't worth re-duplicating), but the shape of both:

- Investigate/mine in parallel (one dispatched agent per item or per repo), then synthesize and ask for approval back in the main thread — never one-at-a-time in the main thread, and never write anything before you've approved it.
- `#<n>` numbering and `[stack: <name>]` assignment (`plan-tasks`) — a stable identity per task, and the dependency/shared-file analysis that makes stacked overnight PRs mergeable in the right order. Deliberately biased toward stacking ("when in doubt, stack") since a false `solo` risks two PRs conflicting with no ordering to resolve it.
- No-arg mode (both): fans out across every repo under `PROJECT_REPOS_DIR` (or the ones that qualify — see `## discover.sh` / `## plan.sh` above) in parallel, then reviews and finalizes them one at a time, in order.
- Finalize: commits, opens a PR, and — new — merges it once you've approved the content earlier in that same session. See Safety model below for the scope of that.

Skills live in a named folder with a `SKILL.md` inside (not a flat `.md` file directly under `.claude/skills/`) — that's the format Claude Code actually discovers. `disable-model-invocation: true` means each only runs when explicitly called via its slash command, never auto-triggered. Both run interactively and never touch application code — only `TASKS.md` and `docs/nightlight-meta.json`.

## Scripts

```bash
pnpm nightlight [repo] [--scan] [overnight flags]  # ./nightlight.sh [repo] [--scan] [overnight flags]
pnpm discover [repo] [--scan]                       # ./discover.sh [repo] [--scan]
pnpm plan [repo]                                     # ./plan.sh [repo]
pnpm overnight some-repo                             # ./overnight.sh some-repo
pnpm stats [some-repo]                               # ./stats.sh [some-repo]
```

Thin `package.json` wrappers around the shell scripts — no dependencies, nothing to `pnpm install`. Args pass straight through to the script (pnpm doesn't need a `--` separator the way npm does), so `pnpm plan some-repo` and `./plan.sh some-repo` are identical. Use whichever reads better; the rest of this README uses the raw `./script.sh` form since it's unambiguous about what's actually running.

## Usage

```bash
# mine memory for task candidates first, if any have accumulated
./discover.sh some-repo

# breakdown next (see plan.sh above) if TASKS.md has anything new or vague
./plan.sh some-repo

# the actual overnight run
./overnight.sh some-repo
```

`discover.sh`/`plan.sh` with no repo run across every repo under `PROJECT_REPOS_DIR` (see `## discover.sh` / `## plan.sh` above) — but they're still two separate commands, run whenever you want; discover doesn't automatically feed into plan. Since discover's Finalize now merges its own PR (see Safety model below), running `plan` any time after `discover` already sees whatever discover found, with no manual merge step in between.

`./nightlight.sh some-repo` (see `## nightlight.sh` above) is the equivalent of the three commands above, chained into one, with a confirmation pause before the `overnight.sh` step.

`overnight.sh` resolves a bare name against `$PROJECT_REPOS_DIR` (from `.env`) or accepts a full path. Run it inside `tmux` or a terminal window you can leave open — closing the window kills the process. Disable sleep/hibernate for the duration.

Only run one repo at a time per machine (shared usage pool). Chain sequentially if you need more than one: `./overnight.sh repo-a && ./overnight.sh repo-b`.

### Limiting a run

Flags scope a single run without editing `TASKS.md` or `CLAUDE.md`. They *append* to the base prompt rather than replacing it, so the workflow rules, quality gates, and end-of-session housekeeping still apply — only the task scope changes.

```bash
./overnight.sh some-repo --stop-after 27     # complete through task #27, then stop
./overnight.sh some-repo --limit 3           # complete 3 tasks this run, then stop
./overnight.sh some-repo --stack auth        # only tasks in [stack: auth], skip every other stack
./overnight.sh some-repo --extra-instructions "double check the migration is reversible"
```

`--stop-after N` refers to a task's permanent `#<n>` number (see TASKS.md format below), not a count and not a position in the file. The agent works through tasks in file order and stops once it's completed task `#N`, without starting anything numbered higher — since numbers only increase down the file as tasks are added, this reliably targets one specific task, unlike a position-based count that would silently point somewhere else the moment an earlier task gets archived. Note this is a boundary check on the number, not a filter on the walk: if TASKS.md isn't in strict numeric order (e.g. `#5` was inserted above `#3`), the agent still works top-to-bottom, so it completes `#5` on the way to `#3` even though `5 > 3`.

`--limit N` is the count-based counterpart: stop after dispatching N tasks this run, whatever their numbers happen to be or however each one turns out (done, `NEEDS HUMAN`, or `blocked` all count against the limit — it's a count of subprocesses run, not of successes). Use `--stop-after` when you want a specific task as the boundary; use `--limit` when you just want "do a few and stop." The two flags are deliberately separate rather than one overloaded flag (e.g. `5` vs `#5`) — a bare number is ambiguous between "a count" and "a task number," and that ambiguity is exactly the kind of silent-wrong-behavior risk this tool should avoid in an unattended run.

`--stop-after`, `--stack`, `--extra-instructions`, and `--override-prompt` require a single target repo — they're rejected in the no-arg "run every repo" mode, since scoping to one task number/stack/prompt across multiple unrelated repos isn't a coherent request. `--limit` is the exception: given with no repo, it applies independently to each repo's own run (first N tasks in that repo, in that repo's file order) rather than being a global count across all repos combined.

```bash
./overnight.sh --limit 2                     # every repo with open work, first 2 tasks each
```

There's also `--override-prompt "<text>"`, which bypasses the per-task dispatch loop entirely and runs `<text>` as a single, one-off session instead — no task selection, no stack-notes, no housekeeping afterward. Reach for the flags above first — an override loses the housekeeping and workflow-rules framing unless `<text>` restates it.

Each dispatched subprocess runs `claude -p` with `--output-format stream-json`, so its events (assistant text, tool calls, tool results) arrive incrementally rather than all at once at the end. Each line is piped through `format-stream.jq`, so the terminal you launched `overnight.sh` from shows clean, readable progress live — no separate `tail -f` needed. You'll see a `=== session started ===` / `=== session done: ... ===` pair once per task (plus one more for housekeeping) rather than a single pair for the whole run, since each is its own fresh `claude -p` call. The agent opens one PR per task as it finishes, so a `gh pr create` call showing up in that live output is your signal that task is done and ready to check, rather than waiting for the whole run to finish.

Three files land in `logs/`, all gitignored: `<repo>-<date>.jsonl` (the raw NDJSON event stream, unformatted, kept for later inspection or tooling), `<repo>-<date>.log` (the same `format-stream.jq` output shown live in your terminal, saved as-is), and `<repo>-<date>.stderr.log` (anything any `claude` process wrote to stderr, kept separate so it doesn't break the JSON stream). Every dispatched subprocess this run appends to the same three files, so a full night's work for one repo still lands in one place per day.

Switching to `stream-json` only changes how the CLI reports events to us locally — it doesn't change what the agent does or what it costs. Each subprocess's closing `result` event includes its own `total_cost_usd`, which `format-stream.jq` prints as that subprocess's summary line, and which also feeds `stats/<repo>.json` (see [stats.sh](#statssh) above) — a separate, gitignored directory from `logs/`, since one is raw per-subprocess debug output and the other is a small running-totals reference meant to survive longer than a day's log file.

## Behavior notes

- **The run doesn't pause between tasks, but each task is its own session.** `overnight.sh` dispatches every Agent-Ready, Verify, and Research item as its own fresh `claude -p` subprocess, one after another with no human gate in between, stopping only once everything is complete, annotated `NEEDS HUMAN`, or annotated `blocked` — not after each task. Unlike a single continuous session, though, each task starts with a clean slate: it has no memory of any other task, only what its prompt hands it (the task text itself, and — for stacked tasks — that stack's `docs/stack-notes/<stack>.md`).
- **Within a stack, later tasks don't wait for earlier ones to be reviewed.** Each task branches from the previous task's branch tip (resolved for it by `overnight.sh`'s dispatch loop, from stack-notes), so task 2 builds on task 1's code as soon as it's written, regardless of whether you've looked at task 1's PR yet. A `NEEDS HUMAN` annotation on task 1 (missing env var, API key, etc.) doesn't pause the stack — the code is presumed complete, just not fully runnable without that step.
- **`blocked` is for cross-stack dependencies, not same-stack ordering.** It only gets used when a task turns out mid-implementation to depend on work in a *different* stack. If a task's correctness genuinely depends on the real-world outcome of an earlier same-stack task's human-verification step (not just on that task's code existing), there's no automatic rule catching that today — it falls to the agent's judgment under the general "ambiguous, annotate why, skip it" rule.

## TASKS.md format (in the target repo)

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

- **Agent-Ready** — implemented in file order, each with acceptance criteria.
- **Verify** — confirmed or implemented, whichever the codebase needs.
- **Research** — produces a markdown doc, never touches code.
- **Decisions (human only)** — never attempted by the agent.
- **`#<n>`** — a stable, never-reused task number assigned during `/plan-tasks`, on every section, not just Agent-Ready. It's what lets a PR, commit, or `## Discovered` note reference a specific task after it's been checked off and archived out of `TASKS.md`. Tracked in `docs/nightlight-meta.json`'s `nextTaskNumber` field in the target repo.
- **`[stack: <name>]`** — tasks sharing a stack name are branched and PR'd in sequence (each targets the previous branch); tasks with no annotation are treated as continuing the previous task's stack. `solo` is a reserved name and the one exception: every `solo`-tagged task, including an unannotated task that inherits `solo` via the fallback rule above, branches from `main` and PRs to `main` independently, never chained to other `solo` tasks, no matter how many share the tag. Assign these during `/plan-tasks`, not by hand.

## What you get in the morning

- One PR per task, each targeting either `main` or the previous branch in its stack.
- One `chore: session housekeeping <date>` PR that updates `TASKS.md`, adds `docs/tasks-archive/<date>.md`, and updates the `tasksCompleted`/`tasksBlocked` counts in `docs/nightlight-meta.json` — the only PR that touches any of the three.
- Anything the agent couldn't finish is annotated `NEEDS HUMAN: <steps>` (env vars, API keys, dashboard config) or `blocked: <reason>` (judgment calls, missing context) directly in `TASKS.md`, and in the relevant PR description.

Merge stacks bottom-up. Merge solos and housekeeping whenever.

## Safety model

No `--dangerously-skip-permissions`. `.claude/settings.json` is an explicit allowlist (test/lint/build commands, safe git operations, PR creation) plus an explicit denylist (`main`/`master` push, merge, `rm -rf`, `.env` reads, `--no-verify`). The agent can't merge its own work or push to a protected branch — everything it produces is a PR waiting for you to look at it. If a task needs judgment or credentials it doesn't have, it's supposed to stop and annotate rather than guess.

**One narrow, deliberate exception:** `/discover-tasks` and `/plan-tasks` Finalize each merge their own PR (`gh pr merge --squash --delete-branch`) once it's open, rather than leaving it for you to merge by hand. This isn't the agent deciding what's safe to land — every item going into that PR was already explicitly approved by you earlier in that same session (candidate-by-candidate in discover's Phase 2, or the full breakdown/numbering/stacking proposal in plan's Synthesize). The merge just completes something you already signed off on. It's scoped tightly on purpose: `.claude/settings.json` only allows `gh pr merge` for branches matching `chore/tasks-discover-*` / `chore/tasks-plan-*` — raw `git merge` stays denied everywhere, for every branch, no exceptions — and those branches only ever touch `TASKS.md`/`docs/nightlight-meta.json`, never application code. `overnight.sh`'s task PRs and its end-of-session housekeeping PR are untouched by this — those still always wait for you, exactly as before.

## Prior art

This isn't the only take on "run Claude Code overnight." A few others, for comparison:

- [night-shift](https://github.com/ppuliu/night-shift) — Claude and Codex adversarially review each other's work so no single model grades its own homework. Runs with `--dangerously-skip-permissions`.
- [ClaudeNightsWatch](https://github.com/aniketkarne/ClaudeNightsWatch) — a daemon that fires a task file right before your usage window resets, rather than a manual trigger.
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — a literal loop: PR, wait for checks, merge, repeat.
- [Boucle](https://github.com/Bande-a-Bonnot/Boucle-framework) — cron-scheduled, with its own persistent-memory layer across runs.

The main difference here: this system never bypasses permissions, and code changes always wait for a human-reviewed merge. Everything above defaults to skipping permission prompts for the autonomous run; this one trades some autonomy for an explicit allowlist instead — the only self-merges it ever does are `discover`/`plan`'s own already-approved `TASKS.md` bookkeeping (see Safety model above), never application code.
