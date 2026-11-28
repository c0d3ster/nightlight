<img align="right" style="float: right; margin: 0 0 16px 24px;" src="docs/NightlightLogo.png" alt="nightlight logo: a glowing green plug-in nightlight" width="260" />

# nightlight

Leave a light on while you sleep. nightlight runs unattended Claude Code sessions against a repo's task list and opens the work as reviewable PRs. It never touches `main`.

It's plain bash with no dependencies, dashboard or daemon. It reaches into a target repo with `--add-dir` for one session at a time and leaves nothing behind.

<br clear="right" />

## How it works

- `overnight.sh` runs one fresh `claude -p` session per open task, plus one for housekeeping at the end. Tasks share no memory, so a task's cost is bounded by its own work.
- Sessions launch from this repo, so its `CLAUDE.md` (workflow rules) and `.claude/settings.json` (permissions) apply to every target repo. The target's own `CLAUDE.md` supplies its conventions and test command, and is never edited.
- Each task gets its own `overnight/<date>/*` branch and PR. Tasks in the same `[stack: <name>]` chain onto each other and pass context forward through stack notes. A later task sees only the latest entry.
- Each task ends with a `TASK_RESULT` line. Housekeeping checks those against the real branch and PR state, then updates the task list.

## Requirements

- Bash 4.3+. macOS ships 3.2, so `brew install bash` and put it first on `PATH`.
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in.
- Git, [`jq`](https://jqlang.org/download), and the GitHub CLI authenticated with `gh auth login`. Every GitHub call is REST through `gh api`, so it also works in Claude Code cloud sessions, which block GraphQL.
- Optional: [pnpm](https://pnpm.io), used only as a script alias runner.
- A target repo with a task list and a `CLAUDE.md` naming its test command.

## Setup

1. Clone this repo somewhere permanent and `chmod +x *.sh`.
2. Copy `.env.example` to `.env` and set `PROJECT_REPOS_DIR` to the folder holding your repos.
3. Adjust `CLAUDE.md` and `.claude/settings.json` if the defaults don't fit.
4. Optional: run `bash install.sh` to use the skills from inside any repo (see [Skills](#skills)).

`.env` is gitignored. It holds `PROJECT_REPOS_DIR`, and optionally `NIGHTLIGHT_MODEL` and `LINEAR_API_KEY`. The scripts read it before `claude` starts. The `Read(.env)` deny rule only stops the agent from reading env files.

Target repos aren't added through Claude Code's `additionalDirectories` setting, which would be a permanent grant. The scripts pass `--add-dir` per run instead.

## Commands

Every script has a `pnpm` alias that takes the same args.

| Script | pnpm | What it does |
| --- | --- | --- |
| `./discover.sh [repo] [--deep]` | `pnpm discover` | turn the repo's memory and PRDs into task candidates (with `--deep`, also its README, code and other docs) |
| `./plan.sh [repo]` | `pnpm plan` | break tasks down, number them, assign stacks |
| `./overnight.sh [repo] [flags]` | `pnpm overnight` | the unattended run |
| `./nightlight.sh [repo] [--deep] [flags]` | `pnpm nightlight` | discover, plan and overnight chained, with a `[y/N]` before overnight |
| `./migrate.sh <repo> --to github\|linear` | `pnpm migrate` | move `TASKS.md` into issues, or adopt existing issues |
| `./tidy.sh <repo> [--labels\|--no-labels]` | `pnpm tidy` | close shipped or stale GitHub issues; `--labels` labels the rest |
| `./stats.sh [repo]` | `pnpm stats` | cost, time and task totals |
| `./install.sh [--unlink]` | `pnpm install-skills` | link the skills and agents into `~/.claude` |
| `bash test/run.sh` | `pnpm test` | the test suite (bash, a `gh` stub, no network; CI runs it on every PR) |

- **Repo argument:** a bare name resolves against `PROJECT_REPOS_DIR`, and a full path also works. With no repo, `discover`, `plan`, `overnight` and `nightlight` cover every repo there with work to do.
- **Latest rules:** `discover`, `plan`, `overnight`, `migrate` and `tidy` pull nightlight first.
- **Interactive scripts:** `discover`, `plan`, `migrate` and `tidy` open a normal session with the skill already typed in, and write nothing until you approve.

```bash
/write-prd                  # optional, in a session: draft a PRD in docs/prd/
./discover.sh some-repo     # optional: collect task candidates
./plan.sh some-repo         # break down anything new or vague
./overnight.sh some-repo    # the unattended run
```

## Running overnight

Run it in `tmux` or a window you leave open, with sleep disabled. Run one repo at a time per machine, since they share a usage pool: `./overnight.sh repo-a && ./overnight.sh repo-b`. With no repo, it runs every eligible repo in turn.

```bash
./overnight.sh some-repo --stop-after 27     # through task #27
./overnight.sh some-repo --limit 3           # dispatch 3 tasks
./overnight.sh some-repo --stack auth        # only [stack: auth]
./overnight.sh some-repo --extra-instructions "check the migration is reversible"
./overnight.sh some-repo --force             # kill leftover sessions, take a stale lock
```

- **`--stop-after N`** takes a task number, not a count. Tasks still run in order, so it marks where to stop.
- **`--limit N`** counts dispatched tasks, however each one ends.
- **One repo only:** `--stop-after`, `--stack`, `--extra-instructions` and `--override-prompt` need a single repo. `--limit` and `--force` apply per repo.
- **`--override-prompt "<text>"`** runs one bare session with no task loop or housekeeping.
- **Stopping:** Ctrl+C stops the run and kills its sessions. Closing the window on Windows doesn't, and the next run refuses to start until you pass `--force`.
- **Usage limits:** if the five-hour usage window runs out, the run sleeps until it resets and retries, up to 3 times per task. A weekly limit counts as a failure.
- **Failures:** two failed dispatches in a row stop that repo's run.
- **Stacks:** tasks don't wait for review. Each task builds on the previous task's branch, even when that one needs a human step.

Live output shows one `=== session started ===` / `=== session done ===` pair per task. A `gh api -X POST .../pulls` line means a PR was opened. Logs go to `logs/<repo>/<date>/`, named like the branches: `r<R>-<PP>-<t|i><NN>-<slug>.{jsonl,log,stderr.log}`, with `i` for issue tasks. Housekeeping gets its own set, and `r<R>-run.log` holds the whole run.

## Skills

| Skill | Script | What it does |
| --- | --- | --- |
| `/write-prd` | none | drafts a PRD in `docs/prd/` with you and opens a PR for it |
| `/discover-tasks [--deep]` | `discover.sh` | proposes task candidates |
| `/plan-tasks` | `plan.sh` | breaks tasks down, assigns `#<n>` numbers, stacks (it leans toward stacking, since a wrong `solo` risks conflicting PRs) and acceptance criteria |
| `/migrate-tasks --to github\|linear` | `migrate.sh` | moves `TASKS.md` into issues, or adopts existing ones |
| `/tidy-issues [--labels]` | `tidy.sh` | reviews open unlabeled GitHub issues |

Every skill investigates first and asks before writing.
- **Local mode:** the only writes are the task list and `docs/nightlight-meta.json`, through a small PR the skill merges once you've approved its content.
- **GitHub and Linear mode:** the writes are issues and labels.
- **`/write-prd`:** writes only the PRD, through a PR it never merges.

**Where tasks come from:** write a PRD with `/write-prd`, merge it, then run `/discover-tasks`.
- **Default:** discover reads the known work: the repo's Claude memory and every PRD in `docs/prd/` not marked `done`. Each PRD unit becomes a candidate with its stack, dependencies and open decision. `/plan-tasks` keeps a `PRD: docs/prd/<file> <unit>` reference on every task, which is how a later discover knows the unit is tracked.
- **`--deep`:** also checks README claims against the code, TODOs and skipped tests, other plan and spec docs with how much is implemented, and whether PRD units are already built. Research docs are always opt-in; you pick them from a list.
- **Two repos:** one PRD per repo, each listing only its own units and linking the other. A unit that waits on the other repo stays in Discovered until that work lands.

The skills use two subagents, `task-scout` and `task-investigator`, which live in `.claude/agents/`.

**Target repo**, in this order:
1. the `--add-dir` repo, which is what the scripts pass
2. a repo named in the args (`/plan-tasks my-repo`, as a sibling checkout's name or a path)
3. the repo you're in, if it isn't nightlight
4. otherwise the skill lists the checkouts beside nightlight and asks

In a Claude Code cloud session there's no `--add-dir`, so name the target or pick it when asked.

**From inside any repo:** run `bash install.sh` once per machine. Nothing links automatically. It symlinks the skills into `~/.claude/skills/` and the agents into `~/.claude/agents/`, so a `git pull` here updates them. Re-run it only when a skill or agent is added.
- **Existing entries:** it deletes nothing. An existing copy of the same name moves to `~/.claude/backups/nightlight/`, and anything else is skipped.
- **Removing:** `--unlink` removes only links into this checkout.
- **Windows:** on Git Bash, enable Developer Mode first. The script sets `MSYS=winsymlinks:nativestrict` and stops if it still gets a copy instead of a link.

This is a stopgap until nightlight ships as a plugin.

**Permissions outside nightlight:** a skill run from another repo enforces the same denylist. Skills can't ship permission rules, so each skill and agent registers `lib/guard.sh` as a pre-tool-use hook that applies the deny rules in `.claude/settings.json`.
- **Allowlist:** it doesn't carry over, because a hook can deny a call but not pre-approve one. Calls it would have allowed go to auto mode's classifier, or prompt you in other modes.
- **Subagents:** only nightlight's two subagents are covered. The skills dispatch no others.
- **Managed machines:** a managed `strictPluginOnlyCustomization` setting turns skill hooks off.

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
<!-- raw candidates; /plan-tasks triages them -->
```

- **Sections:**
  - **Agent-Ready** tasks are implemented in order.
  - **Verify** tasks are confirmed, or implemented if missing.
  - **Research** tasks produce a markdown doc, never code.
  - **Decisions** are never attempted.
- **`#<n>`** is a permanent number assigned by `/plan-tasks` from `nextTaskNumber` in `docs/nightlight-meta.json`. It's never reused.
- **`[stack: <name>]`:** tasks with the same stack run in sequence, each branching from the previous one. A task with no tag inherits the previous task's stack. `solo` tasks branch from `main` independently.
- **Glyphs:** `[!]` means blocked and `[/]` means it needs a human. Only housekeeping sets them.

### GitHub issues (opt-in)

In the target repo's `docs/nightlight-meta.json`:

```json
{ "taskSource": "github", "github": { "repo": "owner/name" } }
```

- **Tasks:** an open issue with a section label is a task, and its issue number is the task id. `github.repo` defaults to the repo's `origin`.
- **Labels:** `nl:agent-ready`, `nl:verify`, `nl:research`, `nl:blocked`, `nl:needs-human`, `nl:stack:<name>`, plus `nl:decision` and `nl:discovered`, which are never dispatched. The runner and skills create missing labels through `lib/ensure-labels.sh`.
- **Overriding names:** under `labels`, using the keys `agentReady`, `verify`, `research`, `blocked`, `needsHuman`, `decision`, `discovered`, `stackPrefix`, `priorityHigh` and `priorityLow`.
- **Order:** by issue number. The optional `nl:priority:high` and `nl:priority:low` labels move whole groups up or down; a stack ranks by its best member and is never split.
- **Non-solo stacks** are also GitHub milestones.
- **Stack notes** are comments on a `stack-notes: <stack>` issue.
- **Housekeeping** closes an issue once its PR merges, and sets the blocked and needs-human labels with a comment.

**Public repos:** issue text is untrusted input to an agent with write tools. The section label is the gate, since applying one needs triage access. Only comments from owners, members and collaborators reach the task, so keep triage access to people you trust.

### Linear (opt-in)

```json
{
  "taskSource": "linear",
  "linear": {
    "teamId": "ENG",
    "statuses": { "queued": "Todo", "started": "In Progress", "review": "In Review", "done": "Done" }
  }
}
```

- **Tasks:** open issues on that team with a section label. Their ids look like `ENG-142`, so `--stop-after` doesn't work; `--limit` and `--stack` do.
- **One team per repo:** don't share a team. Labels and the team are the only scope, so repos sharing a team would run each other's tasks.
- **`statuses`** is optional. Each phase takes a status name, or `null` to leave the issue alone; `queued` defaults to `null`, and the others default to the values shown.
- **Who moves status:** the runner sets `queued` and `started`, and housekeeping sets `review` and `done`. Housekeeping also restores any issue a run left behind to its original status, recorded in `logs/<repo>/status-ledger.json`.
- **Milestones and notes:** non-solo stacks are milestones inside a Linear project, and stack notes are a `stack-notes: <stack>` document.
- **Why two channels:** the bash runner can't call MCP, so it reads through Linear's GraphQL API with `LINEAR_API_KEY`. Writes go through the Linear MCP server, so the key never reaches the model and each operation can be allowed or denied separately.

Setup:
1. `gh auth login`, still needed for PRs.
2. `LINEAR_API_KEY=...` in an env file. The target repo's env files are checked before nightlight's, gitignored files first, in the order `.env.local`, `.env.*.local`, `.env.*`, `.env`. Templates are skipped, and a warning prints if the file isn't gitignored.
3. `claude mcp add --scope user --transport http linear https://mcp.linear.app/mcp`, then sign in with `/mcp`.

### Migrating

`pnpm migrate <repo> --to github` (or `linear`) moves open `TASKS.md` items into issues and archives the checked-off ones. Decisions become `nl:decision` issues and Discovered items `nl:discovered`. It then flips `taskSource` in a small PR.
- **Approval:** it dedupes against existing issues and merged PRs, and asks before each create.
- **Re-runs:** safe, since created issues carry a `Migrated from TASKS.md` marker.
- **Adopting issues** in a repo with no `TASKS.md` (GitHub only): `pnpm tidy <repo> --labels` labels them one at a time with your approval, then `pnpm migrate <repo> --to github` flips `taskSource`.

## Model

Overnight sessions default to `sonnet`. Set `NIGHTLIGHT_MODEL` in `.env` for every repo, or `"model"` in a repo's `docs/nightlight-meta.json` for one; the repo setting wins. Use an alias (`opus`, `sonnet`, `haiku`) to follow new releases, or a full model id to pin one version. The interactive skills use your session's model, and the two subagents use the `model:` in `.claude/agents/`.

## What you get in the morning

- One PR per task, targeting `main` or the previous branch in its stack.
- Unfinished work marked `NEEDS HUMAN: <steps>` or `blocked: <reason>`, in the task list and the PR description.
- **Local mode:** one `chore: session housekeeping <date>` PR. It's the only PR that touches the task list, the archive in `docs/tasks-archive/` and `docs/nightlight-meta.json`, so task PRs never conflict with it.
- **GitHub and Linear mode:** tracker updates and deleted merged stack branches, with no PR on a normal run.

Merge stacks bottom-up. Merge solo and housekeeping PRs in any order.

`pnpm stats` reads `stats/<repo>.json`, which every session's cost, time and tokens are added to. Remote modes also read task counts from labels. One line per run goes to `stats/<repo>-history.jsonl`. `total_cache_read_tokens` should grow roughly in line with the work done; see `docs/stats-schema.json`.

## Safety model

- **No `--dangerously-skip-permissions`.** Overnight sessions run with an explicit allowlist and a denylist in `.claude/settings.json`. Anything the allowlist doesn't cover is refused.
- **The allowlist** covers tests, lint, build, safe git, and `gh api` on the issues, pulls, labels, milestones and search endpoints.
- **The denylist** blocks:
  - pushes naming `main` or `master` in any form, and force pushes
  - `git merge`, and `--no-verify` or `-n` on commit
  - `git -c` and option injection through `git -C`
  - `rm -rf` and `.env` reads
  - `gh api` DELETE, merge, `contents` and `git` endpoints
  - Linear's delete tools
- **No self-merges:** sessions can't merge their own work or edit the permissions.
- **Blocked tasks:** a task that needs judgment or credentials it lacks stops and is marked for you.

The denylist matches command text, so it's a guardrail, not a sandbox. It misses combined short flags like `git commit -anm`, `git push --mirror` and `--all`. It also refuses a commit message that contains ` -c ` or ` -n`. Turn on branch protection for `main` on every target repo: that's what actually enforces it.

**One exception:** `/discover-tasks` and `/plan-tasks`, and `/migrate-tasks` after a separate yes, merge their own task-list PR once you've approved its content. They do it through `lib/merge-pr.sh`: a rebase merge over REST, then a best-effort branch delete.
- The script only merges `chore/tasks-discover-*`, `chore/tasks-plan-*` and `chore/tasks-migrate-*` branches, and the allowlist only permits it for those.
- Raw `gh api` merges and `git merge` stay denied.
- Overnight task and housekeeping PRs always wait for you.

## Prior art

- [night-shift](https://github.com/ppuliu/night-shift): Claude and Codex review each other's work. Uses `--dangerously-skip-permissions`.
- [ClaudeNightsWatch](https://github.com/aniketkarne/ClaudeNightsWatch): a daemon that fires a task file just before your usage window resets.
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude): a loop of PR, wait for checks, merge, repeat.
- [Boucle](https://github.com/Bande-a-Bonnot/Boucle-framework): cron-scheduled, with memory across runs.

The difference here: permissions are never bypassed, and code always waits for a human merge.
