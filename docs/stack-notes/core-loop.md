# core-loop

## `#9` Add TASKS.md status glyphs and auto-archive NEEDS HUMAN tasks on PR merge

Branch: overnight/2026-09-27/09-tasks-glyphs-auto-archive

Key decisions:
- Glyphs (`[ ]` / `[!]` / `[/]`) are documentation-only: this codebase's housekeeping step is a dispatched Claude session that follows CLAUDE.md prose, not a bash routine in `overnight.sh`, so the acceptance criteria are met by updating CLAUDE.md's "Section semantics in TASKS.md" and "TASKS.md maintenance" sections rather than adding parsing/regex code.
- Kept the free-text annotation (`NEEDS HUMAN: <steps>` / blocked reason) alongside the glyph rather than replacing it — the glyph gives an at-a-glance status, the text still carries the actual detail housekeeping and humans need.
- Added one line to `build_housekeeping_prompt()` in `overnight.sh` (the only code change) telling the housekeeping subprocess to check merge state of *every* `[/]` line already in TASKS.md each run, not just tasks dispatched this run — otherwise a `[/]` task from a prior run whose PR merged later would never get swept, since it wouldn't appear in that run's `TASK_RESULT` summary.
- No existing TASKS.md lines needed migrating to the new glyphs — grepped for `NEEDS HUMAN`/`blocked` and found none currently annotated as such (only the task descriptions themselves mention those words).

No interfaces/exports created — this is a docs + prompt-text change, no new code surface.

No deviation from acceptance criteria.
