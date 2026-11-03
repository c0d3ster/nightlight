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

## #18 Mode detection in `/plan-tasks` and `/discover-tasks` skills

Branch: overnight/2026-10-20/r2-06-t18-skill-mode-detection

- Both skills gained a "Task source mode" section and a "Dedupe (every mode)" section, inserted before existing content. No existing line was edited, so local-mode text is untouched.
- Mode is read per repo via `source lib/task-source.sh && load_task_source <repo>`, which also loads the `ts_*` functions the dedupe step calls.
- Remote (`github`) deltas: discover Phase 3 runs `gh issue create --label nl:discovered`, Phase 4 skipped; plan uses `nl:discovered` issues as its items, skips `#<n>` assignment, applies section/stack labels via `gh issue edit` (breakdowns as a comment), skips Finalize. Neither touches TASKS.md or opens a chore PR.
- Dedupe: `ts_find_related` per candidate/Discovered item, `task-scout` verify mode for matches that look implemented, every match shown with state, per-match choice (skip, reopen, link as follow-up, create anyway), no silent drops. Existing discover Phase 2 step 2 cross-reference left in place.
- Interfaces: none new in code (skill docs only). Linear is not documented in the skills (module not implemented yet).
- Deviation: none. Not exercised live (skills are prompts).

## #19 Remote housekeeping path (GitHub)

Branch: overnight/2026-10-20/r2-07-t19-remote-housekeeping-github

- `build_housekeeping_prompt()` now returns early to new `build_housekeeping_prompt_github()` when `TASK_SOURCE=github`. The local body is untouched (output verified byte-identical).
- GitHub prompt: confirm real PR state, close issues `--reason completed` with a PR-link comment only after the PR merged, `nl:blocked` + reason, `nl:needs-human` + steps, close `nl:needs-human` issues whose PR merged, flag (comment + PR body, no label change) contradictory labels. No TASKS.md or archive writes; `tasksCompleted`/`tasksBlocked` still go through the housekeeping commit + PR; stack-notes sweep kept, using `nl:stack:<name>` open issues instead of TASKS.md tags.
- Label names come from `ts_gh_label`, so `labels` overrides in meta.json apply.
- Interfaces: `build_housekeeping_prompt_github` in `overnight.sh`.
- Deviation: none. Not exercised live (prompt text only); the `[!]` dependency-resolved sweep has no remote analog in the plan, so it is not included.

## #20 GitHub mode permissions and docs

Branch: overnight/2026-10-20/r2-08-t20-github-mode-permissions-docs

- `.claude/settings.json`: allow `gh issue view/list/comment/create/edit/close`, `gh label list/create`, `gh pr view/list`, `git push origin --delete overnight/*` and `git branch -D overnight/*` (housekeeping needs them; the user-level `Bash(*)` on the author's machine had masked the gap), deny `gh issue delete` and `gh repo delete`. No blanket `gh` or MCP allow.
- CLAUDE.md: new "GitHub mode" subsection inserted before "Task numbering". Existing local-mode lines untouched.
- README: new "GitHub Issues task source (opt-in)" section before "TASKS.md format", stating local stays the default, covering `taskSource`, `github.repo`, labels, and the public-repo label-permission caveat.
- Interfaces: none (docs and settings only).
- Deviation: documented the labels override keys from `ts_gh_label` usage (`agentReady`, `verify`, `research`, `blocked`, `needsHuman`, `stackPrefix`); `nl:discovered` default taken from the #18 notes.

## #32 `pnpm migrate`: local TASKS.md to GitHub issues

Branch: overnight/2026-10-20/r2-09-t32-migrate-tasks-to-github

- `migrate.sh <repo> --to github` (wired as `pnpm migrate`) launches `/migrate-tasks --to github` with the repo attached. Repo arg is required, no no-arg fan-out; only `--to github` is accepted.
- `.claude/skills/migrate-tasks/SKILL.md`: dedupe via `ts_find_related` (plus a `Migrated from TASKS.md #<n>` body search for idempotency), approval-gated issue creation, review of unlabeled open issues via `task-scout` verify mode, then a `chore/tasks-migrate-<date>` PR that archives old items to a new `docs/tasks-archive/<date>-migrated.md` and flips `taskSource`. The flip only happens after issues exist.
- `.claude/settings.json`: allow `gh label create`, push and merge for `chore/tasks-migrate-*`.
- Interfaces: `migrate.sh`, `/migrate-tasks` skill.
- Deviation: not exercised live against GitHub. Decisions and Discovered sections are left in TASKS.md rather than migrated. A wording slip in SKILL.md's label line (Phase 2 step 2) could not be fixed because the edit was permission-blocked.

## #22 Linear OAuth-persistence gate and MCP tool inventory

Branch: overnight/2026-11-02/r2-01-t22-linear-mcp-gate

- Persistence PASS: 7 independent `claude -p` launches (6 with explicit `--allowedTools`, 1 relying on `.claude/settings.json`) called `whoami`/`list_teams` with no re-prompt. Read-only calls only. Long-term refresh not proven.
- Deliverable: `docs/research/linear-mcp.md` with real tool names and params. Existing allow entries already cover everything needed, so no settings change.
- Findings: no delete tools exist in the server, so the `delete_*` deny entries are dead; `save_issue` is create-or-edit; `--allowedTools` swallows a positional prompt (use stdin); settings emit `git -C * ...:*` rule warnings.
- Recommendation: `whoami` preflight in `overnight.sh` for Linear mode; allow `save_project`/`save_milestone` only when needed.
- Deviation: none; docs only.

## #23 Linear: `.mcp.json` and `LINEAR_API_KEY` resolver

Branch: overnight/2026-11-02/r1-02-t23-linear-mcp-json-key-resolver

- Added `lib/env.sh` with `env_get VAR DIR...`: prints the first value of VAR found in the env files of the first DIR that has one, reading one line with `sed` and never sourcing. Gitignored files (per `git check-ignore`) are tried before the rest, each group in the order `.env.local`, `.env.*.local`, `.env.*`, `.env`. Templates (`.example`, `.sample`, `.template`, `.dist`) are skipped, quotes and CR are stripped, and it warns on stderr when the value comes from a file that is not gitignored. Reusable for any env var.
- `lib/task-source.sh` sources it and, in the `linear` branch of `load_task_source`, runs `env_get LINEAR_API_KEY <target> .` (target repo first, then nightlight's own dir) and exports the result; it errors if none is found. The agent-side `Read(.env)` / `Read(.env.*)` deny is untouched.
- Deviation: `.mcp.json` was NOT created. The harness blocked writes to it as a sensitive file. Needs human: create `.mcp.json` at the repo root with `{"mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}`.
- Verified by hand in scratch repos: key in an ignored `.env.local`, template-only (rejected), tracked-only (warns), nightlight fallback, and absent (error).

## #24 Add `lib/task-source-linear.sh`

Branch: overnight/2026-11-02/r1-03-t24-linear-task-source-module

- Added `lib/task-source-linear.sh` implementing the `ts_*` contract with `TS_NUMERIC_IDS=0`. Same record shape as the other modules (`<id>\t<stack>\t<blockfile>`); ids are Linear identifiers, `ts_task_result_re` matches the bare identifier (`^TASK_RESULT: ENG-142 `).
- One GraphQL query (paged, 100 per page) feeds `ts_is_eligible` and `ts_list_tasks` via a per-run cache file. Filter: team (key, or UUID auto-detected), state type not completed/canceled, any section label. Drops `nl:blocked` / `nl:needs-human` client-side; order is `createdAt`. Stack comes from `nl:stack:*`, inheriting the previous task's, else `solo`.
- `ts_find_related` queries open and closed issues by case-insensitive title/description match, prints `open|closed\t<id>\t<title>`.
- Auth header is the raw key (Linear personal keys take no `Bearer`). `TS_LINEAR_URL` is overridable for tests.
- `--stop-after` error already comes from `run_repo()` checking `TS_NUMERIC_IDS != 1`; no change needed there.
- Deviation: comments are all included (Linear has no author-association field; only workspace members can comment). Tested only against a mocked `curl`, never live.

## #25 Linear housekeeping and skill write paths via MCP

Branch: overnight/2026-11-02/r1-04-t25-linear-write-paths

- Added `build_housekeeping_prompt_linear()` to `overnight.sh`, dispatched from `build_housekeeping_prompt()` when `TASK_SOURCE=linear`. Mirrors the GitHub variant: Done only after the PR merged (checked via `gh pr`), blocked / needs-human labels, PR-link comments, contradictory-label flagging, merged-PR sweep. Every tracker write goes through `mcp__linear__*` (`save_issue`, `save_comment`, `create_issue_label`); meta.json counters and the stack-notes removal still use the housekeeping commit + PR.
- Task prompt gets a Linear paragraph (read via `get_issue`/`list_comments`, no closing keywords, no label edits).
- Label names come from `ts_linear_label`.
- Added `linear` branches to the `/plan-tasks` and `/discover-tasks` skills (Task source mode): items and writes go through `list_issues`, `save_issue`, `save_comment`, `create_issue_label`, `list_issue_labels`, `list_issue_statuses`; `save_issue` replaces the label list, so callers resend kept labels. The `mcp__linear__*` allow entries landed separately in PR #89.
- The dispatch loop's existing-PR skip (`find_task_pr`) now covers `linear` as well as `github`, and both it and `find_orphan_branches` match the task id case-insensitively, because a session may lowercase `ENG-142` in its branch name. Without it a Linear task whose PR was still open would be re-dispatched on the next run.
- Verified by hand with a stubbed `gh`: open, merged and closed PR lookup, a lowercased branch, and prefix ids (`ENG-14` does not match `ENG-142` or `ENG-1420`).

## #26 Linear permissions and docs

Branch: overnight/2026-11-02/r1-05-t26-linear-permissions-docs

- `.claude/settings.json`: the narrow Linear allow entries and the `delete_*` denies landed separately in PR #89 (a superset: `whoami`, `list_teams`, `get_team`, `list_projects`, `list_milestones` were added for the preflight and milestone work), so this PR has no settings change.
- CLAUDE.md: new "Linear mode" section after GitHub mode. README: new "Linear task source" section (config, `gh auth login`, key resolution order, `claude mcp add`, `gh` still required, Linear's GitHub integration not needed). Local and GitHub text untouched.

## #33 `pnpm migrate <repo> --to linear`

Branch: overnight/2026-11-02/r1-06-t33-migrate-to-linear

- `migrate.sh` accepts `--to github|linear`, rejects anything else, and passes `--to $TO` to `/migrate-tasks`. README script list updated.
- `/migrate-tasks` SKILL.md: GitHub text untouched except the args line; new "Linear mode" section at the end (dedupe via `ts_find_related` + marker, MCP `save_issue`/`create_issue_label`, Phase 3 skipped, Phase 4 flips `taskSource` + `linear.teamId`).
- Review fixes: stale frontmatter description updated; the marker search is `Migrated from TASKS.md #<n> (` so `#5` does not match `#50`; every Bash call re-sources the modules and exports `TS_LINEAR_TEAM_ID`/`LINEAR_API_KEY` (shell state does not persist); setup lists the team's existing issues and stops if they look like another repo's (one team per repo); README gains a "Migrating an existing repo" paragraph.
- Deviation: the live run `pnpm migrate c0d3ster --to linear` is a human step (creates real Linear issues); not run here. No permission changes needed.
