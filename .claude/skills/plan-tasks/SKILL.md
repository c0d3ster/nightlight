---
name: plan-tasks
description: Plans and stack-annotates a target repo's TASKS.md. Use when starting a planning session to break down Agent-Ready tasks, assign [stack] annotations, and flag prerequisites before an overnight run.
disable-model-invocation: true
---

A target repo is attached to this session via --add-dir. Read its TASKS.md, its CLAUDE.md, and its docs/nightlight-meta.json (if present — its `nextTaskNumber` field is the next number to assign; treat a missing file as `nextTaskNumber: 1`). For each unchecked item across every section (Agent-Ready, Verify, Research, Decisions):

1. Investigate the relevant parts of the target repo's codebase.
2. Propose a sub-task breakdown with file-level hints and any missing acceptance criteria.
3. Flag missing prerequisites (fixtures, env vars, dependencies) as NEEDS HUMAN annotations.
4. Analyze dependencies AND shared-file overlap between tasks (schemas, barrel exports, shared components), then propose a [stack: <name>] annotation for every task: tasks that depend on each other or touch the same files share a stack name in execution order; genuinely independent tasks get [stack: solo]. When in doubt, stack.
5. Assign each task in the proposal a stable `#<n>` number, starting from `nextTaskNumber` and incrementing by one per task, in the order they'll be written into TASKS.md.

Present the full proposal for my approval BEFORE writing anything. After I approve:

- Write the breakdowns, `#<n>` numbers, and `[stack]` annotations into the target repo's TASKS.md — every checkbox line gets its number right after the checkbox, before the stack tag (e.g. `- [ ] #48 [stack: auth] Add rate limiting to login endpoint`).
- Update `docs/nightlight-meta.json`'s `nextTaskNumber` to one past the highest number just assigned (create the file with `nextTaskNumber`, `tasksCompleted: 0`, and `tasksBlocked: 0` if it doesn't exist yet).

## Finalize

Uncommitted content sitting in the target repo's working tree is dangerous (it can be lost, or silently swept into unrelated work) — do not leave the TASKS.md/nightlight-meta.json edits uncommitted. Once written:

1. Ask me to confirm planning is done for this session and I want these changes committed and opened as a PR. Don't proceed past this step without an explicit yes.
2. Resolve the target repo's default branch: `git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip the `origin/` prefix). If that fails, fall back to checking for a local `main` then `master` branch — same resolution `overnight.sh`'s `default_branch()` helper uses, so this stays consistent with how overnight sessions pick a base branch.
3. Check the target repo's current branch (`git -C <repo> branch --show-current`) against that default. If they don't match, STOP — do not branch, commit, or PR. Tell me plainly which branch it's actually on and that the changes are being left uncommitted in the working tree; committing here would silently fold this into whatever unrelated work is already in progress on that branch. I'll need to switch to the default branch (or handle the commit myself) before re-running finalize.
4. If it matches: pull latest, then create a new branch off it named `chore/tasks-plan-<YYYY-MM-DD>`. If that name already exists locally or on the remote (e.g. a second planning run same day), append `-2`, `-3`, etc.
5. Stage only TASKS.md and `docs/nightlight-meta.json`. Never `git add -A`; the target repo's working tree may hold unrelated uncommitted work that isn't yours to commit.
6. Commit as `chore(tasks): number and stack N task(s)`, with a body listing the task numbers and stack names assigned.
7. Push the branch and open a PR (`gh pr create`) targeting the default branch, title matching the commit, body summarizing the assignments.
8. Report the PR URL.

Do not implement any code in this session.
