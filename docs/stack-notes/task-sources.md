## #13 Extract `lib/task-source-local.sh` from `overnight.sh`

Branch: overnight/2026-10-20/r2-01-t13-extract-task-source-local

- `split_tasks()` moved verbatim into `ts_list_tasks(repo_path, outdir)`. It now takes the repo path and reads `$repo_path/TASKS.md` itself. Regexes unchanged (`#([0-9]+)`, `[stack: ...]`).
- `run_repo()` does `source lib/task-source-local.sh` (relative path, the script `cd`s to its own dir). It still checks `[[ -f TASKS.md ]]` itself before calling `ts_is_eligible`.
- Interfaces in the module: `TS_NUMERIC_IDS=1`, `ts_is_eligible(repo_path)` (exit status), `ts_list_tasks(repo_path, outdir)` (`id\tstack\tblockfile`), `ts_task_result_re(id)` (prints `^TASK_RESULT: #<id> `, used at the single match-site variable `task_result_re` in the dispatch loop), `ts_find_related(repo_path, query)` (case-insensitive fixed-string grep over TASKS.md and `docs/tasks-archive/*.md`; prints `state\tfile:line\ttext`, state `open` or `archived`).
- Not yet done: `taskSource` config dispatch (module is sourced unconditionally), `TS_NUMERIC_IDS` check on `--stop-after`, the other `#$num` match sites (sed patterns on the TASK_RESULT line), and `/discover-tasks` calling `ts_find_related`.
- Verified: `ts_list_tasks` output and concatenated block files are byte-identical to the old `split_tasks` on this repo's TASKS.md.
- Deviation: none.

## #14 Generalize `TASK_RESULT` matching and `--stop-after` to opaque task ids

Branch: overnight/2026-10-20/r2-02-t14-generalize-task-result-ids

- New module function `ts_task_result_label(id)` (local: `#<id>`). It is the one place the id format is written; `ts_task_result_re` now builds on it, and `build_task_prompt` and the synthesized "unknown" TASK_RESULT line call it too.
- The two `sed` extractions in the dispatch loop use `^TASK_RESULT: [^ ]* status=...` instead of `#$num`. They only run on a line already validated by `task_result_re`, so the id stays opaque.
- `run_repo()` errors (returns 1) right after sourcing the module when `--stop-after` is set and `TS_NUMERIC_IDS != 1`. The `-gt` comparison in the loop is unchanged and is the only numeric use of the id.
- Not done: `record_task_entry` still passes `--argjson num` and `docs/stats-schema.json` still says `taskNumber` is an integer, so a non-numeric source will need that relaxed when one is added.
- Deviation: none.
