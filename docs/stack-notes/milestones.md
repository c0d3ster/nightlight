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
