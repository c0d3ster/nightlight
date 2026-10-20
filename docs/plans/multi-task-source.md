# Multi-task-source: shared foundation + GitHub Issues

Status: draft plan, not yet implemented. This is a planning document (no
Research task produced it). It exists to be broken down via `/plan-tasks`
into numbered, stacked work. It supersedes the standalone Linear plan, whose
Linear-specific content now lives in Phase 3.

## Why one document

Linear and GitHub Issues are both "second backlog stores" selected per target
repo. About half the work is identical (the source abstraction, config switch,
`TASK_RESULT` generalization, skill mode detection, housekeeping split) and
should be built once, source-agnostically. The rest is small and
source-specific. So three phases, in build order:

- **Phase 1, shared foundation.** Build it against GitHub as the first
  non-local consumer, since GitHub needs no new credential, MCP server, or
  OAuth gate. That makes it the cheapest way to prove the abstraction.
- **Phase 2, GitHub Issues source.** Deliberately thin.
- **Phase 3, Linear source.** Only what differs: credential, MCP actions,
  non-numeric ids, and the OAuth rollout gate.

Local `TASKS.md` stays the default. A repo with no `taskSource` field behaves
exactly as it does today.

## Phase 1: Shared foundation

### 1.1 Per-repo switch

Extend the target repo's `docs/nightlight-meta.json`:

```json
{
  "taskSource": "local",
  "github": { "repo": "owner/name" },
  "linear": { "teamId": "ENG" }
}
```

`taskSource` is `"local"` (default, or missing), `"github"`, or `"linear"`.
Only the block for the chosen source is read. This is the single gate every
divergence below hangs on.

### 1.2 Task-source interface

Extract `lib/task-source-<name>.sh`, sourced by `run_repo()` based on
`taskSource`. Every module implements the same contract:

- `ts_is_eligible(repo_path)`: any open dispatchable work? Queried once;
  the same result feeds the loop (no double API hit).
- `ts_list_tasks(repo_path, outdir)`: emits today's tab-separated
  `id\tstack\tblockfile` shape. `blockfile` is a synthesized task body
  (title, description, acceptance criteria) so `build_task_prompt` never
  needs to know the source.
- `ts_task_result_re(id)`: the regex that matches this task's own
  `TASK_RESULT` line.
- `ts_find_related(repo_path, query)`: open AND closed items whose title or
  body match a candidate, with state and id. Used by the skills' dedupe step
  (see 1.6). Local: TASKS.md plus `docs/tasks-archive/*.md`. GitHub:
  `gh issue list --state all --search`. Linear: MCP search.

`lib/task-source-local.sh` is today's `split_tasks()` and the
`grep -Eq '^\s*- \[ \]'` gate moved as-is. Its regex stays exactly
`#([0-9]+)`. `resolve_base_branch`, `build_task_prompt`,
`build_housekeeping_prompt`, `extract_task_result` and stack-branch
bookkeeping stay untouched; they already treat the id as opaque except for
`--stop-after` (see 1.4).

### 1.3 `TASK_RESULT` contract

Generalize `TASK_RESULT: #$num status=...` to `TASK_RESULT: <task-id>
status=...`. Local and GitHub keep `#<n>` (both are plain integers).
Linear uses its bare identifier. One prompt-contract change, shared by all
sources, replacing the hardcoded `#$num` at the three match sites in
`overnight.sh`.

### 1.4 `--stop-after`

It's a numeric comparison. It works as-is for local and GitHub (issue
numbers are monotonic integers). Non-numeric sources (Linear) error clearly
when it's passed rather than silently no-op'ing. Each module declares
`TS_NUMERIC_IDS=1|0` and the flag check reads that.

### 1.5 Label and section vocabulary

One label scheme for every remote source, so skills and housekeeping don't
fork per source. The mapping from TASKS.md concepts:

| TASKS.md | Remote source |
|---|---|
| `## Agent-Ready`/`Verify`/`Research`/`Decisions`/`Discovered` | labels `nl:agent-ready`/`nl:verify`/`nl:research`/`nl:decision`/`nl:discovered` |
| `[stack: <name>]` | label `nl:stack:<name>` (no stack label = inherit previous, `nl:stack:solo` = solo) |
| `[!]` blocked, `[/]` NEEDS HUMAN | labels `nl:blocked`, `nl:needs-human`, set only by housekeeping |
| `[ ]`/`[x]` | the source's native open/closed state stays authoritative, never shadowed by a label |
| `docs/stack-notes/<stack>.md` | unchanged, stays a file in the target repo |
| `docs/tasks-archive/` | not used; the source's own closed-issue history is the archive |

Labels are configurable via a `labels` block (keys `agentReady`, `verify`,
`research`, `decision`, `discovered`, `blocked`, `needsHuman`, `stackPrefix`)
but default to the names above. Known downside: labels aren't mutually
exclusive, so a partial write can leave contradictory labels. Housekeeping
detects and flags that, never silently resolves it.

### 1.6 Skills: mode detection and shrunk Finalize

`/plan-tasks` and `/discover-tasks` get a short preamble: read `taskSource`
per attached repo before choosing a write path.

- Remote mode, discover: Phase 3 creates issues labeled `nl:discovered`.
- Remote mode, plan: the "assign `#<n>`" step disappears (the source already
  assigned an id); Synthesize applies section and stack labels instead.
- Phase 4 (commit + PR + merge) is **skipped** in remote mode. There's no
  file diff and the write landed on approval.
- Local mode keeps its write path; its dedupe is upgraded as below.

**Dedupe against existing work (both skills, every mode).** Today
`/discover-tasks` silently drops candidates already covered by open TASKS.md
items or `docs/tasks-archive/*.md`, and `/plan-tasks` doesn't dedupe at all.
In remote mode the tracker replaces both the open list and the archive, so
closed issues must be searched too or duplicates slip through. New behavior:

1. For each candidate (discover) or Discovered item (plan), call
   `ts_find_related` before proposing anything.
2. If a match looks implemented, confirm with a cheap code check before
   asking: dispatch `task-scout` in verify mode (candidate plus related items
   in the prompt; it reports implemented, partial, or not implemented with
   `path:line` evidence).
3. Show every match in the proposal: id, state (open, closed, or looks
   implemented), and a one-line reason. Ask per match: skip the candidate,
   reopen the closed item, link the candidate to it as a follow-up, or
   create it anyway.
4. Never drop a candidate silently. A wrongly dropped task is worse than a
   duplicate you can decline.

**Read-only agents carry the investigation work.** `.claude/agents/` holds
`task-investigator` (per-item investigation for `/plan-tasks`: section,
breakdown, prerequisites, touch-points) and `task-scout` (discover's scan
passes, plus a verify mode for the dedupe code check above). Both are
report-only. The skills keep every write path (issues, labels, `#<n>`,
Finalize), so remote mode changes only the skills' write steps, never the
agents. An agent's prompt is source-neutral: the item or candidate text plus
a repo path, so an issue body works the same as a `TASKS.md` item.

### 1.7 Housekeeping split

Reconciling `TASK_RESULT` against real `git`/`gh` state is already
source-agnostic. Per source:

- **Local**: unchanged (TASKS.md + archive + meta in one commit).
- **Remote**: update labels / close issues / comment PR links through the
  source's own write path. `tasksCompleted`/`tasksBlocked` in
  `docs/nightlight-meta.json` still need their own small housekeeping
  commit + PR, since that file is nightlight bookkeeping and not the backlog.

`stats/*.json` needs no changes.

### 1.8 Docs and permissions pattern

- `CLAUDE.md`: Overnight Agent Workflow sections get remote-mode language
  alongside local-mode language, not replacing it.
- `README.md`: new opt-in section per source.
- `.claude/settings.json`: narrow per-command allow entries, never a blanket
  allow, plus explicit denies for delete-shaped commands (defense in depth,
  mirrors the existing `rm -rf` / `git merge` denies).

## Phase 2: GitHub Issues source

### 2.1 Why this is simpler than Linear

| Concern | Linear | GitHub |
|---|---|---|
| Auth | New `LINEAR_API_KEY`, `.env` resolution order | `gh` is already authenticated and already used by `overnight.sh` |
| Agent write path | MCP server, OAuth, tool names unverified | `gh issue edit/comment/create`, same CLI the agent already uses for PRs |
| Unattended-auth risk | OAuth persistence across fresh `claude -p` processes needs an empirical gate | None new; `gh` auth is a static token |
| Bash listing | curl + GraphQL | `gh issue list --json` |
| Id format | New (`ENG-142`) | `#<n>`, same as today |

No MCP server, no `.mcp.json`, no rollout OAuth gate, no new secret.

### 2.2 Listing (bash)

```bash
gh issue list --repo "$gh_repo" --state open --label nl:agent-ready \
  --json number,title,body,labels,author,createdAt --limit 200
```

Run once per section label (agent-ready, verify, research), merge, and sort
by issue number ascending (creation order, which is also stack order). `jq`
extracts the `nl:stack:*` label for the stack column. Skip any issue also
labeled `nl:blocked` or `nl:needs-human`. `gh_repo` defaults to the target
repo's own `origin` (`gh repo view --json nameWithOwner`) and can be
overridden by `github.repo` (backlog in a separate tracker repo).

### 2.3 Agent actions (inside each task subprocess)

The task prompt tells the agent its issue number and to use `gh`:

- Read full detail and comments: `gh issue view <n> --comments`.
- Cross-link: the task PR body references the issue as `` `#<n>` `` in
  backticks, per the existing rule. Keep this: stacked PRs target their
  predecessor branch, and an auto-link or `Closes` keyword on a non-default
  base would be misleading anyway. Closing is housekeeping's job.
- The task session still never sets status labels itself. It reports via
  `TASK_RESULT`, and housekeeping translates.

New allow entries (names are real here, unlike Linear's):
`Bash(gh issue view:*)`, `Bash(gh issue list:*)`, `Bash(gh issue comment:*)`,
`Bash(gh issue create:*)`, `Bash(gh issue edit:*)`. Deny
`Bash(gh issue delete:*)` and `Bash(gh repo delete:*)`.

### 2.4 Trust boundary (the one new risk)

Issue bodies and comments are untrusted text fed into an unattended agent
with write tools. On a private solo repo that's fine. On a public repo, any
stranger can open an issue. Mitigations, cheapest first:

1. **The label is the gate.** Only issues carrying an `nl:*` section label
   are dispatched, and applying a label requires triage/write access.
   Strangers can't dispatch work. This alone covers most cases.
2. Include only comments from authors whose `authorAssociation` is `OWNER`,
   `MEMBER`, or `COLLABORATOR` in the synthesized task body. Drop the rest.
3. Document in the README that `taskSource: "github"` on a public repo
   assumes label permissions are tight.

### 2.5 Housekeeping (remote path)

For each dispatched task, after confirming real PR/branch state:

- Merged: `gh issue close <n> --reason completed` with a PR-link comment and
  drop the `nl:*` labels that no longer apply.
- `blocked`: add `nl:blocked`, comment the reason.
- `needs-human`: add `nl:needs-human`, comment the exact steps. Housekeeping
  also checks every `nl:needs-human` issue's linked PR and closes the issue
  once that PR merges (the remote analog of the `[/]` auto-archive).
- Flag any issue carrying contradictory labels (see 1.5).

The merge-based close is why PR bodies don't use `Closes #n`: it keeps the
close event in one place, with the label cleanup.

### 2.6 What's intentionally not used

GitHub sub-issues and issue dependencies ("blocked by") exist, but the plan
keeps stacks as `nl:stack:<name>` labels so the model matches TASKS.md and
Linear one to one. Revisit only if stack labels prove clumsy.

## Phase 3: Linear source

Implements the Phase 1.2 contract in `lib/task-source-linear.sh` with
`TS_NUMERIC_IDS=0`. Everything not listed here is inherited from Phase 1.
Linear's workflow states are authoritative for completion (Todo / In
Progress / Done / Canceled); the `nl:*` labels from 1.5 are layered on top.

### 3.1 Config

```json
{
  "taskSource": "linear",
  "linear": { "teamId": "ENG" }
}
```

`labels` is optional and uses the 1.5 defaults. Labels are used instead of
custom Linear workflow states so opt-in needs no per-team admin setup in the
Linear UI (states are per-team config; labels are creatable via API/MCP).

### 3.2 Credential: target repo's `.env` first, nightlight's as fallback

Resolve `LINEAR_API_KEY` from the target repo's own `.env`, falling back to
nightlight's `.env`. Never blanket-`source` a target repo's `.env`, since it
may hold unrelated or conflicting variables. Extract just the one key with a
targeted `grep '^LINEAR_API_KEY=' "$repo_path/.env"`. This stays
wrapper-script-only, the same carve-out `PROJECT_REPOS_DIR` sourcing relies
on; the existing `Read(.env)` / `Read(.env.*)` deny still stops the agent
reading it. A repo can thus use a different workspace or team than
nightlight's default.

### 3.3 Bash-side listing vs MCP-side action

`run_repo()`'s dispatch loop runs in plain bash before any `claude` session
exists, and bash can't call an MCP tool. So the split is forced:

- **Listing** (`ts_is_eligible`, `ts_list_tasks`): `curl` + `jq` against
  `https://api.linear.app/graphql`, authenticated per 3.2. `id` is Linear's
  identifier (`ENG-142`); `blockfile` is synthesized from title, description,
  and acceptance criteria. Order within a stack is issue creation time;
  Linear's `priority` is a secondary signal only, since nothing forces it to
  be set.
- **Every agentic action** (read issue detail and comments, transition
  labels and state, comment PR links, file `nl:discovered` issues) happens
  inside each `claude -p` subprocess via Linear's MCP server.

Register the server in a new checked-in `.mcp.json`:

```json
{ "mcpServers": { "linear": { "type": "http", "url": "https://mcp.linear.app/mcp" } } }
```

OAuth is established once with `claude mcp add` (interactive). Exact MCP
tool names and params are **unverified**; inspect the real tool list (e.g.
`/mcp` in a scratch session) before any prompt or allow entry hardcodes a
name. Every tool name below is illustrative.

### 3.4 Differences from the GitHub source

- `TASK_RESULT` uses the bare identifier (`TASK_RESULT: ENG-142 status=...`,
  no `#`), via `ts_task_result_re`.
- `--stop-after` errors clearly (1.4); `--limit` and `--stack` work
  unchanged.
- `plan.sh` / `discover.sh` no-arg mode has no eligibility gate today
  (attaches all of `PROJECT_REPOS_DIR`), so Linear repos are classified
  inside the skill, not by a bash-side gate.
- Housekeeping uses MCP calls instead of `gh issue`: transition labels, move
  to Done only if the PR actually merged, post a PR-link comment. Linear's
  issue history is the archive (not git-tracked, a known and accepted gap).
- Task PR bodies reference ids in backticks as usual; Linear has no
  autolink collision, so this is just consistency.

### 3.5 Permissions

Narrow `.claude/settings.json` allow entries per MCP tool actually used
(e.g. `mcp__linear__update_issue`, `mcp__linear__create_comment`,
`mcp__linear__create_issue`; names illustrative), never a server-level
allow. Explicit denies for any delete-shaped Linear tool.

### 3.6 Rollout gate (do not skip)

Before Linear mode runs unattended, verify empirically that Linear's MCP
OAuth session survives many independent `claude -p` launches without
re-prompting. Each task is a fresh process with no shared session state; if
auth lapses mid-run, a whole night of Linear tasks could fail with nobody
present to re-authenticate. This is the first item in the Phase 3 breakdown
and gates the rest.

### 3.7 Linear-specific risks

- Contradictory labels from a partial write (see 1.5): housekeeping flags
  them.
- Linear API rate limits at scale are unverified. Worth a Research task if
  this becomes real.

## Suggested breakdown (for `/plan-tasks`)

Phases 1 and 2 as one stack, in order:

1. Extract `lib/task-source-local.sh` from `overnight.sh` with zero behavior
   change. Verify a local run is identical (regression gate).
2. Generalize `TASK_RESULT` matching and `--stop-after` via the module
   contract.
3. Add `taskSource` / `github` config reading and module selection.
4. Implement `lib/task-source-github.sh` (`ts_is_eligible`, `ts_list_tasks`,
   `ts_task_result_re`) with the 2.4 author filtering.
5. Route `plan.sh` / `discover.sh` eligibility through the module.
6. Skill mode detection and remote Phase 3 / skipped Phase 4; the dedupe
   code check dispatches `task-scout` in verify mode (agent already built).
7. Remote housekeeping path (2.5) plus the meta.json commit.
8. `settings.json` allow/deny entries, `CLAUDE.md`, `README.md`.
9. Dry run against a sandbox GitHub repo: list, dispatch one task, housekeep.

Phase 3 is a second stack that builds on steps 1 to 3 and does not depend on
GitHub steps 4 to 9:

1. OAuth-persistence check across fresh `claude -p` launches (gate). Also
   inspect and record the real Linear MCP tool names.
2. `.mcp.json` and the credential resolver (3.2).
3. `lib/task-source-linear.sh` (curl + GraphQL listing, `TS_NUMERIC_IDS=0`).
4. Linear housekeeping path and skill write path via MCP.
5. `settings.json` entries, `CLAUDE.md`, `README.md`.
6. Dry run against a disposable Linear team.

## Open items

- Rate limits for `gh issue list` across many repos in a no-arg run (likely
  fine, worth one check).
- Whether `nl:` is the right prefix for GitHub, where labels are visible to
  everyone and `nightlight:` might read better. Just strings, cheap to change.
- Pagination: `--limit 200` per section is a guess; real repos may need
  `gh api --paginate`.

## Critical files

- `overnight.sh`: module selection, `TASK_RESULT` generalization
- `lib/task-source-local.sh`, `lib/task-source-github.sh` (new)
- `plan.sh`, `discover.sh`: eligibility via the module
- `lib/task-source-linear.sh`, `.mcp.json` (new, Phase 3)
- `.claude/skills/plan-tasks/SKILL.md`, `.claude/skills/discover-tasks/SKILL.md`
- `.claude/agents/task-scout.md` (verify mode), `.claude/agents/task-investigator.md`
- `.claude/settings.json`: `gh issue` and Linear MCP allow/deny entries
- `docs/nightlight-meta.json`: schema addition (per target repo)
- `CLAUDE.md`, `README.md`

## Verification (once implemented)

- Regression: local-mode runs byte-for-byte unchanged; local regex still
  exactly `#([0-9]+)`.
- Sandbox GitHub repo: `ts_list_tasks` returns issues in number order with
  correct stack columns; labeled-by-stranger and unlabeled issues are not
  dispatched; a non-collaborator comment is absent from the task body.
- One end-to-end task: dispatched, PR opened, `TASK_RESULT: #<n>` matched,
  housekeeping closes the issue only after the PR merges.
- `--stop-after` works against GitHub; errors clearly against a
  non-numeric source.
- `plan.sh` / `discover.sh` no-arg modes still skip repos with no open work
  and attach local repos exactly as before.
- Linear: the OAuth-persistence check first; then in a sandbox team,
  `ts_list_tasks` returns sane data via curl + jq and one dispatched
  subprocess can read its issue, transition a label, and comment via MCP.

## Next step

Do not implement directly from this plan. Feed it into `/plan-tasks` via
`## Discovered` candidates, per this repo's rule that decomposition happens
in a separate planning session.
