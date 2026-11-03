## #34 Make `/migrate-tasks` carry Decisions and Discovered items over

Branch: overnight/2026-11-03/r2-01-t34-migrate-decisions-discovered

### Decisions
- Decisions items get only `nl:decision`; Discovered items only `nl:discovered`. No section or stack label, so neither source dispatches them (listers in `lib/task-source-*.sh` and `overnight.sh` select by section label only; verified, no code change).
- Discovered idempotency marker: `Migrated from TASKS.md discovered-<8-char sha1 of normalized text> (`, normalized = trimmed, whitespace collapsed, lowercased.
- Both skip the shipped-work (PR/branch) check. Checked `[x]` Decisions items are archived like any other.
- Phase 4 does `git rm TASKS.md` when nothing remains, otherwise keeps it with only skipped items.

### Interfaces
- Only skill/doc text changed: `.claude/skills/migrate-tasks/SKILL.md`, `plan-tasks/SKILL.md` (remote Items bullets), `README.md`. No shell code added; labels read via existing `ts_gh_label` / `ts_linear_label` with keys `decision` and `discovered`.

### Deviations
- `.claude/settings.json` untouched. NEEDS HUMAN: allow `Bash(git rm TASKS.md)` and `Bash(git -C * rm TASKS.md)` (narrowest form that covers the skill), then run `pnpm migrate c0d3ster --to linear` to confirm only Decisions `#13` is created (`#12` was already archived as done in c0d3ster).
