---
name: plan-tasks
description: Plans and stack-annotates a target repo's TASKS.md. Use when starting a planning session to break down Agent-Ready tasks, assign [stack] annotations, and flag prerequisites before an overnight run.
disable-model-invocation: true
---

A target repo is attached to this session via --add-dir. Read its TASKS.md and its CLAUDE.md. For each unchecked Agent-Ready item:

1. Investigate the relevant parts of the target repo's codebase.
2. Propose a sub-task breakdown with file-level hints and any missing acceptance criteria.
3. Flag missing prerequisites (fixtures, env vars, dependencies) as NEEDS HUMAN annotations.
4. Analyze dependencies AND shared-file overlap between tasks (schemas, barrel exports, shared components), then propose a [stack: <name>] annotation for every task: tasks that depend on each other or touch the same files share a stack name in execution order; genuinely independent tasks get [stack: solo]. When in doubt, stack.

Present the full proposal for my approval BEFORE writing anything. After I approve, write the breakdowns and [stack] annotations into the target repo's TASKS.md. Do not implement any code in this session.
