# nightlight

This repo is tooling for unattended overnight sessions against target repos. When a session runs, this repo is the working directory and the target repo is attached via --add-dir.

## Design principles

- Weigh efficiency (token/API cost, run time) and cleanliness (output noise, code surface) on every change to this repo. Prefer the leaner option unless there's a concrete reason not to.

## Session topology

- NEVER commit to, branch in, or modify the nightlight repo itself during a session. All code work, branches, commits, and PRs happen in the added target repo (use its path explicitly for git operations).
- The target repo's own CLAUDE.md defines that repo's code conventions and test/lint commands. Follow it for all code written there. Never modify the target repo's CLAUDE.md.

## Overnight Agent Workflow

### Branching & PRs

- Every task carries `#<n>` (assigned during planning, permanent — see Task numbering) and `[stack: <name>]`. `solo` is reserved for genuinely independent tasks — never invent another name for "no dependencies."
- Same-named stacks (other than `solo`) chain in file order: first branches from main, each next from the previous tip; PRs target the predecessor (first targets main).
- `solo` is exempt from chaining: every `solo`-tagged task branches from and PRs to main independently, no matter how many share the tag — solo tasks are never chained to each other.
- No stack tag = inherit the previous task's stack (safe default), including `solo`'s exemption if that's what the previous task was.
- Task turns out to depend on another stack mid-implementation? Stop, annotate blocked with the reason, move on. Never silently re-stack.
- Branch: `overnight/<YYYY-MM-DD>/<NN>-<task-slug>` (NN = stack order). One task = one branch = one PR; commit in logical, revertable chunks.
- Task branches never touch TASKS.md, `docs/nightlight-meta.json`, or `docs/tasks-archive/` — record progress in commit messages.
- Never push to or merge main.

### Task numbering

- Every checkbox line gets `#<n>` right after it — e.g. `- [ ] #48 [stack: auth] Add rate limiting to login endpoint` — across every section, not just Agent-Ready. Assigned only by `/plan-tasks`, never during a work session.
- Numbers come from `docs/nightlight-meta.json`'s `nextTaskNumber`, incrementing monotonically — never reused, never renumbered, even after a task is completed and archived. This is what lets a PR, commit, or `## Discovered` note reference a specific task unambiguously forever.

### Quality gates

- Lint runs via the target repo's pre-commit hooks — never bypass (no --no-verify); fix the code, not the hook.
- Run the target repo's full test suite locally before every PR. CI also runs it, but don't rely on that. Never commit failing tests.

### Task breakdown rules

- Task decomposition happens in a separate planning session, not during execution — don't restructure, reorder, or reprioritize TASKS.md mid-session.
- Exception: sub-checkboxes under the single task you're actively working, to track your implementation plan and progress. Check them off as you go.
- Mid-session work not covered by an existing task goes under `## Discovered` at the bottom of TASKS.md: one-line description + where you found it. Don't implement Discovered items the same session.

### TASKS.md maintenance

- TASKS.md holds only open, blocked, or in-progress items. It has exactly one writer per session: the housekeeping branch.
- At session end, create `overnight/<YYYY-MM-DD>/housekeeping` from main and make one commit that: checks off/removes completed tasks; adds NEEDS HUMAN and blocked annotations from the session; adds Discovered items; archives completed tasks (task number, text, PR number, notes) to a NEW `docs/tasks-archive/<YYYY-MM-DD>.md` (never append to an existing archive file); updates `tasksCompleted`/`tasksBlocked` in `docs/nightlight-meta.json` (create it with `nextTaskNumber: 1, tasksCompleted: 0, tasksBlocked: 0` if missing).
- Open it as its own PR, `chore: session housekeeping <date>`, targeting main — the only PR touching TASKS.md, `docs/nightlight-meta.json`, or the archive, so task PRs merge in any order across any number of nights with zero conflicts.
- Code-complete but needs a human step (env var, API key, dashboard config)? Keep it in TASKS.md as `NEEDS HUMAN: <exact steps>` (via housekeeping), same note in the task PR description — still open the PR.
- Ambiguous or blocked for non-human reasons: annotate why (via housekeeping), skip it, move on. Never guess on judgment calls.

### Research deliverables

- Every Research task's deliverable is a markdown doc — that doc IS the PR; no .md output means the task isn't done.
- Location: path given in the task, defaulting to `docs/research/<topic>.md` in the target repo.
- Structure: ## Summary (2-3 sentences), ## Findings, ## Recommendation (clearly marked as recommendation, not decision), ## Open Questions, ## Sources.
- Cite sources with links. If web access is unavailable or a claim can't be verified, say so explicitly. Never fabricate sources, prices, API limits, or version numbers.
- Research PRs touch only docs/ — no code changes, no default changes, no new dependencies.

### Section semantics in TASKS.md

- "Agent-Ready": implement, in order. Acceptance criteria included per task.
- "Verify (may already be done)": confirm whether the work exists. If done, mark complete with a note (archived at session end). If not, implement.
- "Research": write findings per the Research deliverables rules above. Do not implement or change defaults.
- "Decisions (human only)": never attempt. These require my input.
- "Discovered": raw, un-triaged candidates (no `#<n>`, no `[stack]`) added by `/discover-tasks` or found mid-session. `/plan-tasks` triages each into one of the sections above; nothing stays here once planned.
