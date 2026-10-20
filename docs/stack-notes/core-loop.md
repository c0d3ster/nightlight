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

## `#10` Interrupted-task detection and retry via git branch scan

Branch: overnight/2026-10-20/r1-01-t10-interrupted-task-scan

Key decisions:
- Scan lives in `overnight.sh`'s dispatch loop, per task right before `resolve_base_branch`, so only tasks actually dispatched (after `--stack`/`--stop-after`/`--limit` filtering) are checked. Nothing is written to TASKS.md.
- Orphan = local branch matching `overnight/<date>/r<R>-<PP>-t0*<n>-*` with no PR. Used `gh pr list --state all` rather than open-only: a merged or closed PR also means the attempt wasn't interrupted, and discarding it would redo finished work. If `gh` errors, the branch is skipped, never deleted.
- Orphans are deleted locally and on `origin` (if pushed), then the task is dispatched normally with a `RETRY:` paragraph in its prompt (new optional 8th arg to `build_task_prompt`). This reuses `#1`'s retry-once wording from CLAUDE.md instead of re-implementing it. `#1` is merged on main, so no cross-stack block.
- No cap beyond one retry per run: a task interrupted again will be retried again next run, since discarded branches leave no trace.

Interfaces created: `find_orphan_branches <repo> <num>` and `discard_orphan_branches <repo> <default-branch> <branches...>` in `overnight.sh`; CLAUDE.md Execution model bullet documenting the scan.

Deviation: orphan check treats any PR (not just open) as "not interrupted".

## `#4` Split overnight logs per task

Branch: overnight/2026-10-20/r1-02-t4-split-logs-per-task

Key decisions:
- Logs now live in `logs/<repo>/<date>/`: `r<R>-<PP>-t<NN>-<slug>.{log,stderr.log,jsonl}` per task, `r<R>-housekeeping.*`, `r<R>-override.*`, and `r<R>-run.log` as the combined readable overview. `run_num` is now computed once up front in `run_repo()` (also used by override mode) and the position/`NN` use the same `%02d` formatting as the branch name told to the subprocess.
- `dispatch()` takes an optional 6th arg `run_log` and tees readable output to it as well as the per-task log, so terminal output is unchanged.
- Empty per-task `.stderr.log` files are removed after each dispatch.
- The slug is not computed anywhere else in `overnight.sh` (the subprocess invents its own branch slug), so log slugs are derived from the task title (lowercase, non-alnum to `-`, 40 chars max). They can differ from the branch slug; `r<R>-<PP>-t<NN>` always matches.

Interfaces created: none new; `dispatch()` gained an optional `run_log` arg. README logs section updated; `logs/` was already gitignored.

Deviation: the log slug is title-derived rather than reused from branch naming, since the script never computes a branch slug.
