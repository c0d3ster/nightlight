# task-scout

## `#30` Build the `task-scout` agent

Branch: overnight/2026-10-20/r1-05-t30-build-task-scout-agent

Key decisions:
- `.claude/agents/task-scout.md` is the single source of truth for the Docs and README scan passes, filtering rules, candidate shape, and output contract (Task / Rationale / Source per candidate, or `No candidates.`).
- SKILL.md Phase 2 step 3 now dispatches `task-scout` and points to its contract. The multi-repo flow dispatches `general-purpose` per repo for memory only, plus `task-scout` per repo when `--scan` is passed, all in one message.
- Phase 1 memory mining, self-targeting, and cross-reference rules untouched. `.gitignore` and `.claude/settings.json` needed no change.

Interfaces: agent `task-scout` (tools Read, Grep, Glob, Bash; model sonnet).

No deviation from acceptance criteria.
