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

Do not implement any code in this session.
