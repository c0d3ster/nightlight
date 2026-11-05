## NITE-6 Map non-solo stacks to GitHub milestones in remote (github) mode

Branch: overnight/2026-11-04/r1-01-tNITE-6-github-milestones

### Decisions
- Contract lives in `lib/task-source.sh` (comment) and every module defines both functions, so callers never need a `declare -F` guard. Local and Linear are `return 0` stubs (appended to `lib/task-source-local.sh` and `lib/task-source-linear.sh`).
- `ts_ensure_group <repo> <stack> <description>` / `ts_close_group <repo> <stack>` in `lib/task-source-github.sh`; shared helper `ts_gh_milestone_lookup <title>` prints `<number> <state>`. Milestone title equals the stack name. Both skip `solo`, are idempotent, and always return 0 (warn on a failed `gh api`).
- Lookup uses `repos/$TS_GITHUB_REPO/milestones?state=all` in the URL (not `-f`, which turns gh api into a POST).
- Skills run the functions via `source lib/task-source.sh && load_task_source <repo>`; housekeeping (a claude session) does the same lookup/PATCH with plain `gh api` per its prompt in `build_housekeeping_prompt_github`.

### Interfaces for later tasks
- NITE-7 (Linear): replace the stubs in `lib/task-source-linear.sh` with a real implementation; the contract and docs (2.6) are already written.
- NITE-19: housekeeping prompt now has a Milestones paragraph after the stack-notes sweep.

### Deviations
- Needs the `Bash(gh api repos/*/milestones*)` allow entry in `.claude/settings.json`; not added by this task (tasks must not edit settings). See PR description.
- Token check: `gh api repos/<repo> --jq .permissions` shows push/admin on c0d3ster/nightlight, so milestone writes should work. No live create was performed.

## NITE-7 Map each non-solo stack to a Linear project milestone

Branch: overnight/2026-11-05/r1-01-tNITE-7-linear-milestones

### Decisions
- Live MCP schemas checked: `save_milestone` takes only `project`, `id`/`name`, `description`, `targetDate`; there is no state, so a milestone cannot be completed or reopened by us. Linear derives it from the milestone's issues. So housekeeping is read-only (reports a missing or duplicate milestone) and `ts_close_group` stays a no-op.
- `ts_ensure_group` / `ts_close_group` in `lib/task-source-linear.sh` remain `return 0` stubs (comment updated); all the work is MCP calls in prompts.
- `/plan-tasks` Linear delta now has a Milestones bullet: lookup via `list_projects` + `includeMilestones`, ask/offer-create Project, proposal wording, `save_project`/`save_milestone`/`save_issue` after approval, warn+skip on none or duplicates.
- Docs: CLAUDE.md Linear section, `docs/plans/multi-task-source.md` 2.6, housekeeping prompt (`build_housekeeping_prompt_linear`).

### Deviations
- `mcp__linear__save_project` must be added to the allow list in `.claude/settings.json` (tasks cannot edit settings). `save_milestone` was already allowed.
- No live Project/milestone was created; nothing verified against a real workspace.

## NITE-19 Make remote-source housekeeping PR-less: stack notes in the tracker, label-based counters

Branch: overnight/2026-11-05/r1-02-tNITE-19-pr-less-remote-housekeeping

### Decisions
- Per-module contract (documented in `lib/task-source.sh`): `ts_stack_notes_export <repo> <dir> [stack]` writes `<stack>.md` (entries) and `<stack>.ref` (tracker object); `ts_stack_notes_write_instructions <stack> <ref>` is prompt text for the task session; `ts_stats_counts <repo>` prints `<overnight> <manual> <blocked>`. Local defines none and keeps files/meta counters.
- GitHub notes: tracking issue `stack-notes: <stack>` labelled `nl:stack-notes` (no section label), one comment per entry; finished = retitled `[done] ` and left open (no `gh issue reopen` allowlisted). Linear notes: document `stack-notes: <stack>` in the stack's Project (via milestone lookup) else the team; entries via `save_document` `append`.
- `overnight.sh`: `stack_notes_load` (globals `STACK_NOTES_ALL`/`STACK_NOTES_REF`), `filter_live_entries`, `stack_branch_is_live`. An entry is stale only if its branch is gone AND never had a PR (merged-then-deleted branches stay live). A tracker read failure skips the task. `resolve_base_branch` takes the notes text as its 5th arg; `extract_latest_stack_note` reads stdin.
- Legacy `docs/stack-notes/<stack>.md` in remote mode: read-only fallback while the tracker has no notes for the stack; `git rm`ed by the sweep once finished (`removed-legacy`).
- `lib/stack-notes.sh --remote <dir>`: same branch deletion, prints `finished <stack>` instead of removing; skips entries whose branch is gone with no PR (`ignored-stale`).
- Abnormal run = the sweep printed `removed-legacy` (a staged file removal). Anything else goes to tracker comments and the final message. Housekeeping prompts no longer write `tasksCompleted`/`tasksBlocked`.
- `stats.sh`: per-repo output gets `tasks` (`{source, overnight, manual, blocked}` remote, `{source, completed, blocked}` local); aggregate sums into `tasks` plus `repos_counted`. Schema in `docs/stats-schema.json` `$defs/taskCounts`. Linear closed issues are paged.

### Deviations
- NEEDS HUMAN: add `mcp__linear__get_document`, `mcp__linear__list_documents`, `mcp__linear__save_document` to `.claude/settings.json` allow list (tasks cannot edit settings). The GitHub side needs no new entry (`gh issue create/comment/edit/list` and `gh label create` already allowed). `mcp__linear__save_project` from NITE-7 is still pending too.
- Nothing exercised against live notes: Linear GraphQL queries (documents filter, counts) ran read-only against the real API with zero matching rows; `filter_live_entries`/`stack_notes_load` were checked with a stubbed export in a scratch repo; `gh` paths and the MCP append are untested.
