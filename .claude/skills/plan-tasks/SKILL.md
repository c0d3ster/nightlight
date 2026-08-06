---
name: plan-tasks
description: Plans and stack-annotates a target repo's TASKS.md. Use when starting a planning session to break down Agent-Ready tasks, assign [stack] annotations, and flag prerequisites before an overnight run.
disable-model-invocation: true
---

A target repo is attached via --add-dir. Read its TASKS.md, CLAUDE.md, and docs/nightlight-meta.json (if present — `nextTaskNumber` is the next number to assign; treat a missing file as `nextTaskNumber: 1`).

## Triage Discovered

`## Discovered` holds raw, un-triaged candidates (no `#<n>`, no `[stack]`). For each, decide where it belongs — Agent-Ready (the common case), Verify, Research, or Decisions (needs my judgment) — then plan it like a native item in that section (steps below). Refined items leave Discovered entirely; nothing stays once a planning session touches it.

## Plan each item

For each unchecked item across Agent-Ready, Verify, Research, and Decisions — including ones just triaged out of Discovered:

1. Investigate the relevant parts of the target repo's codebase.
2. Propose a sub-task breakdown with file-level hints and any missing acceptance criteria.
3. Flag missing prerequisites (fixtures, env vars, dependencies) as NEEDS HUMAN annotations.
4. Analyze dependencies AND shared-file overlap (schemas, barrel exports, shared components), then propose `[stack: <name>]`: tasks that depend on each other or touch the same files share a stack name in execution order; genuinely independent tasks get `[stack: solo]`. When in doubt, stack.
5. Assign each task a stable `#<n>`, starting from `nextTaskNumber` and incrementing per task, in write order.
6. Propose where it lands in its section's existing list — default to the bottom, but ask me explicitly where I want each one; I may want something worked first (e.g. a quick bug fix ahead of a bigger feature).

Present the full proposal for my approval BEFORE writing anything — triage decisions, breakdowns/numbers/stack tags, and proposed position per item. After I approve:

- Write the breakdowns, `#<n>` numbers, and `[stack]` tags into TASKS.md at the approved position — every checkbox line gets its number right after the checkbox, before the stack tag (e.g. `- [ ] #48 [stack: auth] Add rate limiting to login endpoint`).
- Remove triaged items from `## Discovered`.
- Update `docs/nightlight-meta.json`'s `nextTaskNumber` to one past the highest number assigned (create it with `nextTaskNumber`, `tasksCompleted: 0`, `tasksBlocked: 0` if missing).

## Finalize

Uncommitted content in the target repo's working tree is dangerous — lost work, or silently swept into unrelated commits. Don't leave the TASKS.md/nightlight-meta.json edits uncommitted. Once written:

1. Confirm planning is done and I want these changes committed + PR'd. Don't proceed without an explicit yes.
2. Resolve the default branch: `git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to local `main` then `master` — same resolution `overnight.sh`'s `default_branch()` uses.
3. Target repo's current branch (`git -C <repo> branch --show-current`) doesn't match that default? STOP — don't branch, commit, or PR. Tell me which branch it's actually on and that the changes are staying uncommitted; committing here would silently fold them into unrelated in-progress work. I'll switch branches or handle it myself, then re-run finalize.
4. Matches: pull latest, branch off it as `chore/tasks-plan-<YYYY-MM-DD>` (append `-2`, `-3`... if taken locally or on the remote).
5. Stage only TASKS.md and `docs/nightlight-meta.json`. Never `git add -A`; the working tree may hold unrelated uncommitted work that isn't yours to commit.
6. Commit as `chore(tasks): number and stack N task(s)`, body listing the task numbers and stack names assigned.
7. Push, open a PR (`gh pr create`) targeting the default branch — title matches the commit, body summarizes the assignments.
8. Report the PR URL.

Do not implement any code in this session.
