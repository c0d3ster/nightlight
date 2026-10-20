## #13 Extract `lib/task-source-local.sh` from `overnight.sh`

Branch: overnight/2026-10-20/r2-01-t13-extract-task-source-local

- `split_tasks()` moved verbatim into `ts_list_tasks(repo_path, outdir)`. It now takes the repo path and reads `$repo_path/TASKS.md` itself. Regexes unchanged (`#([0-9]+)`, `[stack: ...]`).
- `run_repo()` does `source lib/task-source-local.sh` (relative path, the script `cd`s to its own dir). It still checks `[[ -f TASKS.md ]]` itself before calling `ts_is_eligible`.
- Interfaces in the module: `TS_NUMERIC_IDS=1`, `ts_is_eligible(repo_path)` (exit status), `ts_list_tasks(repo_path, outdir)` (`id\tstack\tblockfile`), `ts_task_result_re(id)` (prints `^TASK_RESULT: #<id> `, used at the single match-site variable `task_result_re` in the dispatch loop), `ts_find_related(repo_path, query)` (case-insensitive fixed-string grep over TASKS.md and `docs/tasks-archive/*.md`; prints `state\tfile:line\ttext`, state `open` or `archived`).
- Not yet done: `taskSource` config dispatch (module is sourced unconditionally), `TS_NUMERIC_IDS` check on `--stop-after`, the other `#$num` match sites (sed patterns on the TASK_RESULT line), and `/discover-tasks` calling `ts_find_related`.
- Verified: `ts_list_tasks` output and concatenated block files are byte-identical to the old `split_tasks` on this repo's TASKS.md.
- Deviation: none.
