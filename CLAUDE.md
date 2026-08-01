# nightlight

This repo is tooling for unattended overnight sessions against target repos. When a session runs, this repo is the working directory and the target repo is attached via --add-dir.

## Design principles

- Weigh efficiency (token/API cost, run time) and cleanliness (output noise, code surface) on every change to this repo. Prefer the leaner option unless there's a concrete reason not to.

## Session topology

- NEVER commit to, branch in, or modify the nightlight repo itself during a session. All code work, branches, commits, and PRs happen in the added target repo (use its path explicitly for git operations).
- The target repo's own CLAUDE.md defines that repo's code conventions and test/lint commands. Follow it for all code written there. Never modify the target repo's CLAUDE.md.

## Overnight Agent Workflow

### Branching & PRs

- Each task in the target repo's TASKS.md carries a [stack: <name>] annotation assigned during planning. `solo` is a reserved name for genuinely independent tasks (see below) — never invent other names meaning "no dependencies," use `solo`.
- Tasks sharing a stack name, other than `solo`, are STACKED in file order: the first branches from main, each subsequent from the tip of the previous. Their PRs target the predecessor branch (first targets main).
- `solo` is exempt from the stacking rule above: every task tagged `solo` branches from main independently and its PR targets main, no matter how many other tasks share the `solo` tag in the same session. Solo tasks are never chained to each other.
- If a task has NO stack annotation, treat it as part of the same stack as the previous task (stack-by-default is the safe fallback) — this includes inheriting `solo` (and its exemption from stacking) if that's what the previous task was tagged.
- If during implementation a task turns out to depend on work in another stack, STOP that task, annotate it blocked with the reason, and move on. Do not silently re-stack.
- Branch naming: overnight/<YYYY-MM-DD>/<NN>-<task-slug> (NN = order in the stack). One task = one branch = one PR. Within a task, commit in logical, revertable chunks.
- Task branches NEVER modify TASKS.md or anything in docs/tasks-archive/. Record progress in commit messages.
- Never push to main. Never merge.

### Quality gates

- Lint runs via the target repo's pre-commit hooks. Never bypass hooks (no --no-verify). If a hook fails, fix the code, not the hook.
- Run the target repo's full test suite locally before opening each PR. CI runs tests on the PR too, but do not rely on it. Never commit failing tests.

### Task breakdown rules

- Task decomposition happens in a separate planning session, not during execution. Do not restructure, reorder, or reprioritize TASKS.md during a work session.
- Exception: you may add sub-checkboxes under the single task you are actively working, to record your implementation plan and progress. Check them off as you go.
- Work discovered mid-session that isn't covered by an existing task goes under a "## Discovered" section at the bottom of TASKS.md with a one-line description and where you found it. Do not implement Discovered items in the same session.

### TASKS.md maintenance

- TASKS.md at the target repo root contains only open, blocked, or in-progress items. It has exactly one writer per session: the housekeeping branch.
- At session end, create overnight/<YYYY-MM-DD>/housekeeping from main and make one commit that: checks off / removes completed tasks from TASKS.md; adds NEEDS HUMAN and blocked annotations accumulated during the session; adds Discovered items; writes completed tasks to a NEW file docs/tasks-archive/<YYYY-MM-DD>.md (never append to an existing archive file), each entry with task text, PR number, and notes.
- Open this as its own PR titled "chore: session housekeeping <date>", targeting main. This is the only PR that touches TASKS.md or the archive, so task PRs merge in any order across any number of nights with zero conflicts.
- If a task is code-complete but requires human steps for end-to-end functionality (env var, API key, dashboard config), it stays in TASKS.md annotated "NEEDS HUMAN: <exact steps>" (via housekeeping) and the same note goes in the task PR description. Still open the PR.
- If a task is ambiguous or blocked for non-human reasons, annotate why (via housekeeping), skip it, move on. Never guess on judgment calls.

### Research deliverables

- Every Research task produces a markdown document as its deliverable. That document IS the PR; a research task with no .md output is incomplete.
- Location: the path specified in the task, defaulting to docs/research/<topic>.md in the target repo.
- Structure: ## Summary (2-3 sentences), ## Findings, ## Recommendation (clearly marked as recommendation, not decision), ## Open Questions, ## Sources.
- Cite sources with links. If web access is unavailable or a claim can't be verified, say so explicitly in the doc. Never fabricate sources, prices, API limits, or version numbers.
- Research PRs touch only docs/; no code changes, no default changes, no new dependencies.

### Section semantics in TASKS.md

- "Agent-Ready": implement, in order. Acceptance criteria included per task.
- "Verify (may already be done)": confirm whether the work exists. If done, mark complete with a note (archived at session end). If not, implement.
- "Research": write findings per the Research deliverables rules above. Do not implement or change defaults.
- "Decisions (human only)": never attempt. These require my input.
