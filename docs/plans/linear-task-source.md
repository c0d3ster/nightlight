# Linear as an optional task source for nightlight

Status: approved plan, not yet implemented. This is a planning document, not
a Research deliverable (no TASKS.md Research task produced it) — it exists
to be broken down via `/plan-tasks` into numbered, stacked work.

## Context

`overnight.sh`, `plan.sh`, and `discover.sh` currently assume a target repo's
backlog lives in a committed `TASKS.md`, parsed by hand-rolled bash regex.
This plan adds Linear (linear.app) as a second backlog store, selected per
target repo, using Linear's official MCP server for the actual agentic work
(not just hitting Linear's API from bash and calling it done). Local
`TASKS.md` stays the default — zero behavior change for any repo that
doesn't opt in.

Two design points were resolved directly with the user during planning (not
assumed): whether Linear-mode discover/plan writes need a git-PR ceremony
(no — see §7), and where the Linear API credential lives (target repo's own
`.env` first, nightlight's as fallback — see §2).

## Recommended design

### 1. Per-repo opt-in: extend `docs/nightlight-meta.json`

Add optional fields to the target repo's own (already per-repo, already
git-tracked) `docs/nightlight-meta.json`:

```json
{
  "nextTaskNumber": 13,
  "tasksCompleted": 1,
  "tasksBlocked": 0,
  "taskSource": "local",
  "linear": {
    "teamId": "ENG",
    "labels": {
      "agentReady": "nl:agent-ready",
      "verify": "nl:verify",
      "research": "nl:research",
      "decision": "nl:decision",
      "discovered": "nl:discovered",
      "blocked": "nl:blocked",
      "needsHuman": "nl:needs-human",
      "stackPrefix": "nl:stack:"
    }
  }
}
```

`taskSource` missing, or `"local"` → exactly today's behavior, `linear`
block ignored. This is the single switch every other change below is gated
on.

### 2. Linear API credential: target repo's `.env` first, nightlight's `.env` as fallback

Resolve `LINEAR_API_KEY` by checking the target repo's own `.env` first,
falling back to nightlight's own `.env` if unset there. Don't blanket-
`source` a target repo's `.env` — that's a foreign file that may hold
unrelated or conflicting variables. Extract just the one key with a
targeted `grep '^LINEAR_API_KEY=' "$repo_path/.env"`, same narrow-scoping
spirit as the existing `Read(.env)`/`Read(.env.*)` deny rule (which stops
the *agent* reading a target repo's `.env`; this stays wrapper-script-only,
same carve-out `PROJECT_REPOS_DIR`'s sourcing already relies on). This lets
a repo override the workspace/team nightlight defaults to, without forcing
every Linear-mode repo onto one shared workspace.

### 3. Bash-side listing (curl+jq) vs. MCP-side action — architecturally forced split

`run_repo()`'s dispatch loop (stack resolution, `--stop-after`/`--limit`/
`--stack` filtering, deciding how many subprocesses to spawn) runs in plain
bash *before* any `claude` session exists — bash cannot call an MCP tool.
So:

- **Listing** (`ts_list_tasks`, `ts_is_eligible` — see §4): plain
  `curl`+`jq` against Linear's GraphQL API (`https://api.linear.app/graphql`),
  authenticated with the API key from §2. This is orchestration plumbing,
  parallel to today's `split_tasks()` reading a file.
- **Every agentic action** — reading full issue detail/comments,
  transitioning label/state, posting PR-link comments, filing new
  `nl:discovered` issues — happens **inside** each dispatched `claude -p`
  subprocess via Linear's MCP server. This is the actual integration.
- Register the server in nightlight's own `.mcp.json` (new, checked in):
  ```json
  { "mcpServers": { "linear": { "type": "http", "url": "https://mcp.linear.app/mcp" } } }
  ```
  OAuth is established once via `claude mcp add` (interactive). Note: exact
  MCP tool names/params are **unverified** — Linear's official server's
  precise tool surface needs to be inspected empirically (e.g. via `/mcp` in
  a scratch session) before any prompt or `.claude/settings.json` allow
  entry hardcodes a tool name. Treat every tool name in this plan as
  illustrative.

### 4. `overnight.sh`: task-source abstraction

Extract a small interface so `run_repo()` stops assuming `TASKS.md`:

- `lib/task-source-local.sh` — today's logic moved as-is (the existing
  `split_tasks()`, the `grep -Eq '^\s*- \[ \]'` gate), no behavior change.
- `lib/task-source-linear.sh` — new, implementing the same three-call
  contract:
  - `ts_is_eligible(repo_path, repo_config)` — any open issue under the
    configured labels. Same call as the lister below (query once, both the
    gate and the loop's input come from it — don't hit Linear's API twice).
  - `ts_list_tasks(repo_path, repo_config, outdir)` — emits the same
    tab-separated `id\tstack\tblockfile` shape `split_tasks` produces today;
    `id` is Linear's own identifier (`ENG-142`) instead of a bare int;
    `blockfile` is a synthesized task-body block (title + description +
    acceptance criteria) formatted so `build_task_prompt` doesn't need to
    know which source produced it.
  - `ts_task_result_prefix(id)` — builds the `TASK_RESULT` match regex.
- `run_repo()` picks the module from `docs/nightlight-meta.json`'s
  `taskSource`. `resolve_base_branch`, `build_task_prompt`,
  `build_housekeeping_prompt`, `extract_task_result`, and the stack-branch
  bookkeeping stay untouched — they already treat the task identifier as an
  opaque string except for one place (`--stop-after`'s numeric comparison,
  see below).

**`TASK_RESULT` contract**: generalize from `TASK_RESULT: #$num status=...`
to `TASK_RESULT: <task-id> status=...` — local mode keeps `#12` (continuity
with existing commit/PR references), Linear mode uses the bare identifier
(`ENG-142`, no `#`). This is the one visible prompt-contract change.

**`--stop-after`**: numeric-only by nature (`[[ "$num" -gt "$STOP_AFTER" ]]`)
— doesn't map onto Linear issue identifiers. Recommend: error clearly if
`--stop-after` is passed against a Linear-mode repo, rather than silently
no-op'ing (a silent no-op could make a run do more than the operator
expected). `--limit`/`--stack` are string/count-based and work unchanged
against either source.

### 5. Concept mapping (TASKS.md → Linear)

| TASKS.md | Linear |
|---|---|
| `## Agent-Ready`/`Verify`/`Research`/`Decisions`/`Discovered` | labels `nl:agent-ready`/`nl:verify`/`nl:research`/`nl:decision`/`nl:discovered` |
| `[stack: <name>]` | label `nl:stack:<name>` |
| `#<n>` | Linear's own issue identifier |
| `- [ ]`/`- [x]` | Linear's native workflow state (Todo/In Progress/Done/Canceled) stays authoritative for completion — never shadowed by a label |
| `[!]`/`[/]` (planned, task #9) | labels `nl:blocked`/`nl:needs-human`, layered on top of whatever state the issue is actually in |
| File order within a stack | issue creation time within the shared stack label (default); Linear's `priority` field as a secondary/cross-stack signal only, never the primary in-stack order (nothing forces it to be set) |
| `docs/stack-notes/<stack>.md` | **unchanged, stays a file** — cross-task context consumed by bash (`resolve_base_branch`) and injected into prompts; a file is easier to grep for `Branch: ` than issue comments, and this keeps that function fully source-agnostic |
| `docs/tasks-archive/<date>.md` | not needed — Linear's own issue/label history is the archive (this isn't git-tracked the way the local archive is — a known, accepted gap) |

Labels over custom Linear workflow states, specifically to avoid requiring
per-team admin setup in Linear's UI before opt-in works (states are
per-team config; labels are freely creatable via the API/MCP). Known
downside: labels aren't mutually exclusive, so a partial-failure write
sequence could leave an issue with contradictory labels (e.g. both
`nl:agent-ready` and `nl:blocked`). Housekeeping should detect and flag
this, not silently resolve it.

### 6. `plan.sh` / `discover.sh` eligibility checks

Route through the same `ts_is_eligible` function `overnight.sh` uses
(sourced from `lib/task-source-*.sh`), rather than duplicating Linear query
logic across three entrypoints. Note: `discover.sh`'s no-arg mode currently
has **no** eligibility gate at all (attaches the whole `PROJECT_REPOS_DIR`
unconditionally) — its Linear-mode repo classification happens inside the
skill itself, not via a bash-side gate, matching its existing "no filter,
let the skill sort it out" shape.

### 7. `/plan-tasks` and `/discover-tasks` skill changes

Same phase structure (Investigate/Synthesize/Finalize; Phase 1–4), different
write target and a shrunk Finalize:

- **discover-tasks**, Linear mode: Phase 3 ("write approved candidates")
  calls an MCP issue-creation tool with the `nl:discovered` label instead of
  appending a TASKS.md line. Phase 4 (commit+PR+merge) is **skipped
  entirely** for Linear mode — there's no file diff, the MCP write already
  landed the moment the human approved it in Phase 2, and Linear's own
  issue history is the audit trail. Local mode's Phase 4 is unchanged.
- **plan-tasks**, Linear mode: Synthesize's "assign `#<n>`" step disappears
  (Linear already assigned an identifier at creation); Synthesize instead
  assigns section/stack labels via MCP. Finalize likewise skipped for the
  same reason as discover-tasks. Local mode's Finalize is unchanged.
- Both skill files get a short mode-detection preamble: read
  `docs/nightlight-meta.json`'s `taskSource` per attached repo before
  choosing the write path — same "read config before acting" pattern they
  already use for `nextTaskNumber`.

### 8. Housekeeping under Linear mode

Reconciling `TASK_RESULT` against real `gh`/`git` state is unchanged
(already source-agnostic). Instead of one TASKS.md/archive commit: MCP
calls to transition each issue's section/blocked/needs-human labels, move
to Done if actually merged, and post a PR-link comment.
`tasksCompleted`/`tasksBlocked` in `nightlight-meta.json` still get updated
and still need their own small commit+PR (that file's ownership doesn't
change with task source — it's nightlight-internal bookkeeping, not the
backlog itself). `stats/*.json` needs no changes at all.

### 9. Permissions

Add narrowly-scoped `.claude/settings.json` allow entries per actual Linear
MCP tool used (e.g. `mcp__linear__update_issue`,
`mcp__linear__create_comment`, `mcp__linear__create_issue` — **names
illustrative, confirm against the real registered tool list first**), never
a blanket MCP-server-level allow. Add explicit denies for any delete-shaped
Linear tool, mirroring the existing `rm -rf`/`git merge` denies as
defense-in-depth.

### 10. `CLAUDE.md` and `README.md`

`CLAUDE.md`'s Overnight Agent Workflow sections (Task numbering, TASKS.md
maintenance, Section semantics) get Linear-mode equivalents described
alongside the existing local-mode language, not replacing it. `README.md`
gets a new opt-in section: setting `taskSource`/`linear` in a repo's
`nightlight-meta.json`, the `.env` credential resolution order from §2, and
the one-time `claude mcp add` OAuth step.

## Rollout gate — do not skip

Before Linear mode is used for any real unattended overnight run, verify
empirically that Linear's MCP OAuth session survives many independent,
unattended `claude -p` subprocess launches without re-prompting (each task
is a *fresh* process with no shared session state). If it doesn't, a whole
run's worth of Linear-mode tasks could silently fail mid-run with nobody
present to re-authenticate. This should be the first item in the eventual
breakdown, gating everything else, not an assumption baked into later work.

## Rollout / compatibility

Every divergence point is gated on `taskSource`, which is absent in every
existing target repo today: `run_repo()`'s gate/loop, `plan.sh`/
`discover.sh`'s eligibility checks, and both skills' write paths all fall
back to exactly today's code path when the field is missing. `.mcp.json`'s
mere presence and the new `settings.json` allow entries are additive and
inert for local-mode repos. No existing repo's behavior changes unless a
human explicitly sets `taskSource: "linear"` in that repo's own
`nightlight-meta.json`.

## Open items intentionally left for the eventual `/plan-tasks` breakdown

- Exact Linear MCP tool names/params (needs empirical confirmation, not
  guessable from here).
- Exact label scheme (`nl:` prefix used throughout is a reasonable default,
  cheap to bikeshed later since it's just strings).
- Linear API rate limits at scale (unverified, worth a Research task if this
  becomes real).

## Critical files

- `overnight.sh` — task-source abstraction, `TASK_RESULT` generalization
- `lib/task-source-local.sh`, `lib/task-source-linear.sh` (new)
- `plan.sh`, `discover.sh` — route eligibility through the shared interface
- `.mcp.json` (new) — Linear MCP server registration
- `.claude/settings.json` — narrow per-tool allow/deny entries
- `docs/nightlight-meta.json` — schema addition (per target repo)
- `.claude/skills/plan-tasks/SKILL.md`, `.claude/skills/discover-tasks/SKILL.md`
- `CLAUDE.md`, `README.md`

## Verification (once implemented)

- Regression: confirm local-mode repos are byte-for-byte unchanged —
  `lib/task-source-local.sh`'s regex must still be exactly `#([0-9]+)`,
  existing TASKS.md-driven runs behave identically.
- The OAuth-persistence check above, run before anything else.
- A dry run against a disposable/sandbox Linear team: `ts_is_eligible` and
  `ts_list_tasks` return sane data via `curl`+`jq`; a single dispatched task
  subprocess can read its issue, transition a label, and comment via MCP
  end to end.
- Confirm `plan.sh`/`discover.sh` no-arg modes still correctly skip
  Linear-mode repos with no open work and still attach local-mode repos
  exactly as before.

## Next step

Do **not** implement directly from this plan. Feed it into `/plan-tasks` via
the `## Discovered` candidates below, per this repo's own "task
decomposition happens in a separate planning session" rule — numbering and
stacking are `/plan-tasks`'s job.
