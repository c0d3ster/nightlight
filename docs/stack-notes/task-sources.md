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

## #15 Read `taskSource` config and select the module in `run_repo()`

Branch: overnight/2026-10-20/r2-03-t15-task-source-config

- New `load_task_source(repo_path)` in `overnight.sh`, called first thing in `run_repo()` in place of the hardcoded `source lib/task-source-local.sh`. It reads `docs/nightlight-meta.json` from the target repo's working tree (before the default-branch checkout/pull, so it sees whatever is on disk).
- Sets globals `TASK_SOURCE`, `TS_GITHUB_REPO`, `TS_LINEAR_TEAM_ID`, `TS_LABELS_JSON` (raw optional `labels` object, `{}` if absent). Only the chosen source's block is read; a missing `github.repo` / `linear.teamId` errors.
- Missing file or field means `local`. Invalid JSON, unknown `taskSource`, or a missing `lib/task-source-<name>.sh` (github and linear until later tasks add them) return 1 with a clear message.
- The "no TASKS.md" skip in `run_repo()` now applies only to `local`; other sources go straight to `ts_is_eligible`.
- Not done: nothing consumes the `TS_*` config vars yet; the github/linear modules are future tasks.
- Deviation: none.

## #16 Add `lib/task-source-github.sh`

Branch: overnight/2026-10-20/r2-04-t16-task-source-github

- New `lib/task-source-github.sh` implementing `TS_NUMERIC_IDS=1`, `ts_is_eligible`, `ts_list_tasks`, `ts_task_result_label`, `ts_task_result_re`, `ts_find_related`.
- One fetch per run: `ts_is_eligible` runs `gh issue list` once per section label, merges (dedupes by number), drops `nl:blocked`/`nl:needs-human`, sorts by number, and caches the result in a temp file (`TS_GH_CACHE`). `ts_list_tasks` reads that cache (fetching only if `ts_is_eligible` wasn't called first). Re-sourcing the module per repo resets the cache.
- Block file per issue: `- [ ] #<n> [stack: <x>] <title>`, blank line, body, then comments with `authorAssociation` OWNER/MEMBER/COLLABORATOR only (`### Comment by <login>`). Issue body is included as-is (the section label is the gate). Stack from the `stackPrefix` label, else previous task's stack, else solo.
- Label names honor the `labels` config block (`agentReady`, `verify`, `research`, `blocked`, `needsHuman`, `stackPrefix`) via `TS_LABELS_JSON`.
- `ts_find_related` prints `<open|closed>\t#<n>\t<title>` from `gh issue list --state all --search`.
- `build_task_prompt` gets a github-mode paragraph (gated on `TASK_SOURCE == github`): issue number, `gh issue view <n> --comments [--repo ...]`, backtick `#<n>` in the PR body, no `Closes`, no status labels. Local prompts unchanged.
- Deviation: `load_task_source` no longer errors on a missing `github.repo`; the module falls back to `gh repo view` on the target's origin (per the task). Tested with a stubbed `gh` only, not a live repo.

## #17 Route `plan.sh` / `discover.sh` eligibility through the task-source module

Branch: overnight/2026-10-20/r2-05-t17-plan-eligibility-task-source

- Moved `load_task_source` out of `overnight.sh` into new `lib/task-source.sh` (verbatim); `overnight.sh` and `plan.sh` both source it (cwd is the nightlight checkout in both).
- `plan.sh` no-arg mode now calls `load_task_source` then `ts_is_eligible` per repo instead of the inline grep. The "no TASKS.md" skip applies to local only. A repo whose source fails to load (bad meta, unimplemented linear) is skipped with "task source unavailable".
- `plan.sh` now checks for `jq` like `overnight.sh`.
- `discover.sh` unchanged (no gate in no-arg mode, per the task).
- Tested with temp repos and stubbed `gh`/`claude`: local open/closed/missing TASKS.md and a github repo with no issues. No live GitHub test.
- Deviation: none.
