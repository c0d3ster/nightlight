# TASKS.md — nightlight

This is nightlight working on itself: the target repo for these tasks is the nightlight repo, not Modernizer/Fractaleyez/c0d3ster.

---

## Agent-Ready

- [!] #10 [stack: core-loop] **Interrupted-task detection and retry via git branch scan**
  BLOCKED: Depends on `#1`'s retry-once rule (cross-stack dependency); `#1`'s PR `#40` is still open, not yet merged to main. Retry once `#1` merges.
  Once tasks run as separate subprocesses (see task #2), a session interrupted mid-task (window closed, machine slept) needs to be detected on the next run without writing anything to TASKS.md mid-session, since only housekeeping may write there. Branch names already encode the task's own number as `t<NN>` in `overnight/<date>/r<R>-<PP>-t<NN>-<slug>` (per Branching & PRs) — no separate commit trailer needed. At the start of a session, scan local branches for a `t<NN>` matching every currently-open (`[ ]`) task's `#<n>`; if a matching branch exists with no open PR (`gh pr list`), housekeeping never ran for it — treat it as an interrupted attempt: discard the branch and retry the task once from a clean state, per task #1's retry-once rule. If a matching branch has an open PR, leave it alone; that's just "done, housekeeping hasn't run yet," not interrupted.

  Note: this reuses task #1's retry-once behavior, which lives in a different (solo) stack. If #1 hasn't merged to main by the time this task is reached, treat that as a cross-stack dependency per existing rules (stop, annotate blocked, move on) rather than reimplementing the rule inline.

  Acceptance criteria: session start includes a scan step that identifies orphaned branches (`t<NN>` matches an open task's `#<n>`, no open PR) for open tasks; orphaned branches are discarded and their task retried once from a clean state; branches with an open PR are left untouched. Depends on task #2.

- [ ] #4 [stack: core-loop] **Split overnight logs per task**
  Execution is now subprocess-per-task, but `run_repo()` still tees everything into one `logs/<repo>-<date>.log` (plus `.stderr.log` and the raw log), so isolating "what happened on task 6" means scrolling past the whole run. Give each `dispatch()` its own log files, laid out to mirror the branch schema `overnight/<date>/r<R>-<PP>-t<NN>-<slug>`: folders by repo, then by date, with every run of the same day sharing the date folder and the run told apart by filename. Position and task number stay separate fields because tasks can be inserted out of order after the fact: `PP` is the dispatch position in that run (the sort key), `t<NN>` is the task's permanent `#<n>`.

  Layout under `logs/<repo>/<YYYY-MM-DD>/`: `r<R>-<PP>-t<NN>-<task-slug>.log` (readable), with matching `.stderr.log` and `.jsonl` (raw event stream) siblings; `r<R>-housekeeping.log` (plus siblings) for the housekeeping subprocess; `r<R>-run.log` as the combined overview for that run (every subprocess's readable output appended, as today's single log is). Reuse `run_num`, the zero-padded position, and the slug already computed for branch naming in `run_repo()` (`overnight.sh` ~L821, ~L891) so log names and branch names cannot drift. Create the date folder with `mkdir -p`. Single-prompt override mode (`OVERRIDE_PROMPT`, ~L794) logs to `r<R>-override.log` in the same folder, with `<R>` from `next_run_number`.

  Acceptance criteria: after a multi-task run, `logs/<repo>/<date>/` holds one readable/stderr/jsonl file set per dispatched task named `r<R>-<PP>-t<NN>-<slug>`, one for housekeeping, and one `r<R>-run.log`; a second run the same day adds `r<R+1>-*` files to the same folder without touching the first run's; files sort by run then dispatch position; `PP` and `t<NN>` are separate segments and a task inserted later with a lower `#<n>` still sorts by dispatch position; the terminal output is unchanged; `bash -n overnight.sh` passes; README and any other doc mentioning the old `logs/<repo>-<date>.log` path are updated. Check that `logs/` is gitignored. Depends on the subprocess-per-task task above.

- [ ] #28 [stack: core-loop] **Cap the stack notes injected into a stacked task's prompt**
  Source: 2026-10-11 fractaleyez run; ~8K tokens of mostly irrelevant history per task, growing with each task. `run_repo()` currently does `cat docs/stack-notes/$stack.md` and `build_task_prompt()` embeds the whole file. Add an `extract_latest_stack_note()` helper in `overnight.sh` (near `resolve_base_branch`, awk/sed only, bash 3 and Git Bash friendly) that outputs the last `^## ` block (the immediate predecessor's entry) plus the list of earlier `^## ` headings. Rewrite the stacked branch of `build_task_prompt()` to say: below is the previous task's entry; earlier entries (headings listed) are in `docs/stack-notes/<stack>.md` on disk, read them only if needed. Keep the append-only instruction and entry format; tell tasks to use `###` or lower inside entries. Reword the stale whole-file comments in `dispatch()` and the `overnight.sh` header. Update CLAUDE.md Execution model and README.md (lines ~12, ~220).

  Acceptance criteria: with a 3-entry fixture, the built prompt contains entry 3's body and neither entry 1's nor entry 2's; it names the file path and lists the earlier headings; a one-entry file behaves as today; a file with no `^## ` heading injects whole; a missing file still takes the "starts stack" branch; first-task and solo prompts are byte-for-byte unchanged; `resolve_base_branch()` still reads the last `Branch:` line; `bash -n overnight.sh` passes and a manual dry run against a fixture file confirms the prompt (the repo has no test suite). Locate the `stack_notes=` line by searching for `docs/stack-notes/$stack.md`, not by line number.

- [ ] #29 [stack: core-loop] **Delete `docs/stack-notes/<stack>.md` once the stack is finished**
  Source: 2026-10-11 fractaleyez run, `user-platform.md` grew to 31KB. Extend the housekeeping branch-cleanup sweep to `git rm` the notes file inside the housekeeping commit (git history keeps it). The sweep currently says deletions are outside the commit; the notes-file removal is the one exception. A stack is finished only when ALL hold: every `Branch:` line's PR is MERGED; no open task in TASKS.md carries `[stack: <name>]` under any glyph (`[ ]`, `[!]`, `[/]`); no open PR has a head branch for this stack; no task from the stack was dispatched this run (per `TASK_RESULT` lines). Update `build_housekeeping_prompt()` (rewrite the "git operation, not a file change" sentence, order file removal after the merge-state check, list the removal in the PR body), and CLAUDE.md's housekeeping bullets (commit contents list, "only PR touching" line, sweep bullet) plus a one-line lifecycle note in the Execution model and README.md (lines ~12, ~220).

  Acceptance criteria: a partially merged stack keeps its file; a stack with a dispatched, open, `[!]`, or `[/]` task keeps its file; a `gh` failure keeps the file; a file with zero `Branch:` lines is kept; branch deletion still happens when the file is kept; a resumed stack with no file takes the "starts stack" path and recreates it (state this in CLAUDE.md); the existing `docs/stack-notes/core-loop.md` is not deleted while `core-loop` has open tasks. Local mode only; `#19` and `#25` add the remote-mode variant.

- [ ] #30 [stack: task-scout] **Build the `task-scout` agent**
  Source: memory `project-task-scout-agent`. Wanted as a real custom-agent use case to learn from and optimize. Create `.claude/agents/task-scout.md`: frontmatter `name: task-scout`, `description`, `tools: Read, Grep, Glob, Bash` (Bash read-only: git log, ls), `model: sonnet`. The body is the system prompt: the Docs and README scan passes lifted from `.claude/skills/discover-tasks/SKILL.md` Phase 2 step 3, plus an output contract (per candidate: task text, one-line rationale, source as doc path or README with file:line), report-only (never write or ask), Agent-Ready-shaped candidates (well-scoped, one PR, draft acceptance criteria and file hints, no `#<n>` or `[stack]`), skip `docs/tasks-archive/`, `stack-notes/`, `research/`, and drop anything already in open TASKS.md items or the archive. Edit SKILL.md: Phase 2 step 3 dispatches `task-scout` and points to its output contract; the multi-repo section dispatches `task-scout` directly per repo for the scan (subagents generally cannot spawn subagents); Phase 1 memory mining keeps its current path. Keep SKILL.md lean. Confirm `.gitignore` does not exclude `.claude/agents/`.

  Acceptance criteria: the agent file exists with valid frontmatter, read-only tools, and `model: sonnet`; SKILL.md no longer duplicates the pass text (the agent file is the single source of truth); single-repo and multi-repo flows both reference `task-scout`; self-targeting and cross-reference rules are unchanged; the memory-mining path is unchanged; `.claude/settings.json` needs no change. Lands before `#18` (which also edits SKILL.md).

- [ ] #31 [stack: task-scout] **End-to-end test of `discover-tasks --scan`**
  NEEDS HUMAN prerequisite: an interactive run (the skill requires approval before writing and a yes before commit/PR) against a throwaway target repo, path given by the human. A nightlight self-run is a poor test: it would consume the `task-scout` memory file as a candidate. Run `pnpm discover <repo> --scan` and record the outcome in the PR description. Report as needs-human if no throwaway repo is available.

  Acceptance criteria: the run announces "Found N candidate(s) from memory, M from repo scan" with N>0 and M>0; each scan candidate shows source and rationale; approved items land as unchecked `- [ ]` lines (no `#<n>`, no `[stack]`) under `## Discovered`; only memory-sourced files are deleted; rejected candidates are untouched; the Phase 4 PR targets the default branch and contains only TASKS.md and the memory deletions. Depends on `#30`.

- [ ] #13 [stack: task-sources] **Extract `lib/task-source-local.sh` from `overnight.sh`**
  Plan: `docs/plans/multi-task-source.md` Phase 1.2. Move `split_tasks()`, the `#<n>`/`[stack]` regexes, and the open-work gate (`grep -Eq '^\s*- \[ \]'`) behind the `ts_is_eligible` / `ts_list_tasks` / `ts_task_result_re` contract in a new `lib/task-source-local.sh`, sourced by `run_repo()`. Zero behavior change.

  Acceptance criteria: the local regex is still exactly `#([0-9]+)`; `run_repo()` sources the module; a local dry run produces identical task records and dispatch order to before the extraction; the module also exposes `ts_find_related` (open TASKS.md items plus `docs/tasks-archive/*.md`), the logic `/discover-tasks` runs inline today (plan 1.2, 1.6).

- [ ] #14 [stack: task-sources] **Generalize `TASK_RESULT` matching and `--stop-after` to opaque task ids**
  Plan Phase 1.3, 1.4. Replace the hardcoded `#$num` at `overnight.sh`'s `TASK_RESULT` match sites (prompt contract, `task_result_re`, the two `sed` extractions) with `ts_task_result_re`. Add `TS_NUMERIC_IDS=1|0` to each module; `--stop-after` errors clearly when the active module sets 0 instead of silently no-op'ing.

  Acceptance criteria: local mode still emits and matches `TASK_RESULT: #<n> ...`; the id is treated as an opaque string everywhere except the `--stop-after` check. Depends on `#13`.

- [ ] #15 [stack: task-sources] **Read `taskSource` config and select the module in `run_repo()`**
  Plan Phase 1.1. Read `taskSource` (`local` default, `github`, `linear`) and the `github.repo` / `linear.teamId` blocks plus the optional `labels` block from the target repo's `docs/nightlight-meta.json`; `run_repo()` sources `lib/task-source-<name>.sh` accordingly. Missing file or field means `local`. Unknown values error clearly.

  Acceptance criteria: repos with no `taskSource` behave exactly as today; an unknown `taskSource` fails with a clear message. Depends on `#14`.

- [ ] #16 [stack: task-sources] **Add `lib/task-source-github.sh`**
  Plan Phase 2.2, 2.4. `ts_list_tasks` runs `gh issue list --json number,title,body,labels,author,createdAt` once per section label (`nl:agent-ready`, `nl:verify`, `nl:research`), merges, sorts by issue number, skips `nl:blocked` / `nl:needs-human`, extracts the stack from `nl:stack:*` (no label inherits the previous task's stack, `nl:stack:solo` is solo). `blockfile` is synthesized from title, body, and comments by `OWNER`/`MEMBER`/`COLLABORATOR` only. Repo defaults to `origin`, overridable by `github.repo`. `TS_NUMERIC_IDS=1`, ids are `#<n>`. `ts_is_eligible` shares the same query.

  Acceptance criteria: output matches the tab-separated `id\tstack\tblockfile` shape; issues without an `nl:*` section label are never returned; non-collaborator comments are absent from the block; one API query per run feeds both gate and loop; `ts_find_related` searches open and closed issues via `gh issue list --state all --search`. Depends on `#15`.

- [ ] #17 [stack: task-sources] **Route `plan.sh` / `discover.sh` eligibility through the task-source module**
  Plan Phase 1 (eligibility). Replace the inline `grep -Eq '^\s*- \[ \]'` gate in `plan.sh` with `ts_is_eligible` for the repo's configured source. `discover.sh`'s no-arg mode has no gate today and stays that way; repo classification for remote sources happens inside the skill.

  Acceptance criteria: `plan.sh` no-arg mode still skips local repos with no open tasks and attaches the rest exactly as before; a github-mode repo with no labeled open issues is skipped. Depends on `#16`.

- [ ] #18 [stack: task-sources] **Mode detection in `/plan-tasks` and `/discover-tasks` skills**
  Plan Phase 1.6. Add a preamble reading `taskSource` per attached repo. Remote mode, discover: Phase 3 creates issues labeled `nl:discovered` via `gh issue create`. Remote mode, plan: skip the "assign `#<n>`" step and apply section/stack labels via `gh issue edit` instead. Phase 4 / Finalize is skipped in remote mode. Local mode is unchanged.

  Acceptance criteria: both skill files document both modes; local-mode text is untouched; remote mode never edits TASKS.md or opens a chore PR. Both skills, in every mode, run the plan 1.6 dedupe step: `ts_find_related` per candidate, a cheap code check for matches that look implemented, every match shown with its state, per-match choice (skip, reopen, link as follow-up, create anyway), and no silent drops (`/plan-tasks` gains dedupe it lacks today). Depends on `#16`.

- [ ] #19 [stack: task-sources] **Remote housekeeping path (GitHub)**
  Plan Phase 2.5. After confirming real PR/branch state: close merged tasks' issues (`--reason completed`) with a PR-link comment; add `nl:blocked` with the reason comment for blocked tasks; add `nl:needs-human` with exact steps for needs-human tasks, and close those issues once their PR merges; flag (never silently resolve) issues with contradictory labels. `tasksCompleted` / `tasksBlocked` in `docs/nightlight-meta.json` still go through the small housekeeping commit + PR. Update `build_housekeeping_prompt` accordingly, selected by `taskSource`.

  Acceptance criteria: local-mode housekeeping prompt is unchanged; in github mode no TASKS.md or archive file is written; issues are closed only after their PR merged. Depends on `#16`.

- [ ] #20 [stack: task-sources] **GitHub mode permissions and docs**
  Plan Phase 1.8, 2.3. Add narrow `.claude/settings.json` allow entries (`gh issue view/list/comment/create/edit`) and denies (`gh issue delete`, `gh repo delete`). Document GitHub mode alongside local mode in CLAUDE.md (Task numbering, TASKS.md maintenance, Section semantics) without changing local-mode language, and add a README opt-in section (`taskSource`, `github.repo`, labels, the public-repo label-permission caveat from the plan's 2.4).

  Acceptance criteria: no blanket `gh` or MCP allow; README states local `TASKS.md` stays the default. Depends on `#19`.

- [ ] #21 [stack: task-sources] **GitHub mode dry run against a sandbox repo**
  Plan Phase 2 verification. NEEDS HUMAN prerequisite: a throwaway GitHub repo with the `nl:*` labels and a few seeded issues, path given by the human. Run listing, dispatch one task end to end, and housekeep. Report as needs-human if no sandbox repo is available.

  Acceptance criteria: `ts_list_tasks` returns issues in number order with correct stacks; a stranger-labeled or unlabeled issue is not dispatched; the issue closes only after its PR merges; `--stop-after` works. Depends on `#20`.

- [ ] #22 [stack: task-sources] **Linear OAuth-persistence gate and MCP tool inventory**
  Plan Phase 3.6, 3.3. NEEDS HUMAN prerequisite: the human has run `claude mcp add` for Linear's hosted MCP server. Verify the OAuth session survives many independent unattended `claude -p` launches without re-prompting, and record the real Linear MCP tool names and params. Deliverable: `docs/research/linear-mcp.md` (Summary, Findings, Recommendation, Open Questions, Sources). Docs only. If auth lapses, say so plainly and recommend against unattended Linear mode.

  Acceptance criteria: the doc states pass/fail for persistence with the evidence, and lists the actual tool names later tasks must use. Depends on `#21`.

- [ ] #23 [stack: task-sources] **Linear: `.mcp.json` and `LINEAR_API_KEY` resolver**
  Plan Phase 3.2, 3.3. Add a checked-in `.mcp.json` registering `https://mcp.linear.app/mcp`. Add a resolver in the wrapper scripts that extracts `LINEAR_API_KEY` from the target repo's `.env` via a targeted `grep '^LINEAR_API_KEY='` first, falling back to nightlight's `.env`. Never source the target's `.env` wholesale.

  Acceptance criteria: resolver works with the key in either location; the agent-side `Read(.env)` deny is untouched. Depends on `#22`.

- [ ] #24 [stack: task-sources] **Add `lib/task-source-linear.sh`**
  Plan Phase 3.3, 3.4. `ts_list_tasks` / `ts_is_eligible` via `curl` + `jq` against `https://api.linear.app/graphql`; ids are Linear identifiers (`ENG-142`); order within a stack is creation time; skip `nl:blocked` / `nl:needs-human`; `TS_NUMERIC_IDS=0`; `ts_task_result_re` matches the bare identifier.

  Acceptance criteria: same tab-separated record shape as the other modules; `--stop-after` errors against a Linear-mode repo; one query feeds gate and loop; `ts_find_related` searches open and closed issues via the API. Depends on `#23`.

- [ ] #25 [stack: task-sources] **Linear housekeeping and skill write paths via MCP**
  Plan Phase 3.4. Housekeeping and the remote branches of `/plan-tasks` and `/discover-tasks` use the Linear MCP tools confirmed in `#22`: transition labels, move to Done only if the PR merged, post a PR-link comment, create `nl:discovered` issues. Reuse the remote-mode structure from `#18` and `#19`; only the write path differs.

  Acceptance criteria: no `gh issue` calls in Linear mode; Finalize skipped; meta.json commit path unchanged; the plan 1.6 dedupe flow works in Linear mode, with "reopen" and "link as follow-up" done through MCP. Depends on `#24`.

- [ ] #26 [stack: task-sources] **Linear permissions and docs**
  Plan Phase 3.5. Narrow `.claude/settings.json` allow entries per Linear MCP tool actually used (names from `#22`), explicit denies for delete-shaped tools. Add Linear-mode language to CLAUDE.md and README (setup, `.env` resolution order, `claude mcp add`).

  Acceptance criteria: no server-level MCP allow; local and GitHub text unchanged. Depends on `#25`.

- [ ] #27 [stack: task-sources] **Linear mode dry run against a disposable team**
  Plan Phase 3 verification. NEEDS HUMAN prerequisite: a disposable Linear team and API key. Verify `ts_list_tasks` returns sane data and one dispatched subprocess can read its issue, transition a label, and comment via MCP. Report as needs-human if unavailable.

  Acceptance criteria: end-to-end task completes with the issue updated through MCP only. Depends on `#26`.

- [ ] #11 [stack: solo] **Make DB schema/migration generation NEEDS HUMAN**
  When a task's acceptance criteria require a schema change, the agent currently generates the migration, spins up the dev server, runs codegen, verifies the output, then tears the server down — a measurable, avoidable turn cost (confirmed 2026-08-06, c0d3ster: ~7 extra Bash round-trips per migration-touching task, incurred twice in one session). Change the rule: the agent edits the schema/model file(s) only, then stops — no generate step, no dev server, no codegen — and records the change as NEEDS HUMAN with the exact follow-up commands (generate migration, review generated SQL, start dev server + run codegen, review generated types, apply migration). Applies to any ORM/migration tool, not just Drizzle — this lives in the shared Overnight Agent Workflow section, used across repos with different stacks.

  Acceptance criteria: CLAUDE.md's Overnight Agent Workflow gets a new "Database changes" subsection documenting this; NEEDS HUMAN annotation format spells out the exact command sequence a human runs.

## Verify (may already be done)

- [ ] #5 [stack: solo] **Check Claude Code plan/model eligibility for `--permission-mode auto`**
  `overnight.sh` currently runs `--permission-mode acceptEdits`, which avoids prompting for edits but carries no built-in classifier guardrails beyond our own `.claude/settings.json` allow/deny list. Claude Code's `auto` permission mode adds a second, independent layer of guardrails (no privilege escalation, no force-push, no mass deletion) on top of whatever the allowlist says — but it requires Claude Code v2.1.83+, a Max/Team/Enterprise/API plan (not Pro), an eligible Sonnet/Opus model, and the Anthropic API provider (not Bedrock/Vertex/Foundry). Confirm whether the current setup qualifies. If already eligible, note it as done with the qualifying details (archived at session end per normal Verify rules). If not eligible, leave open with the specific blocker (e.g. "on Pro plan, needs Max+") so it's easy to re-check later.

## Research

- [ ] #6 [stack: solo] **Evaluate git worktrees for isolated secret access on env-var-gated tasks**
  Tasks that need a live env var or API key currently get skipped and annotated NEEDS HUMAN, resolved manually the next morning — this works but costs a full round trip even for secrets we'd be fine pre-approving. Deliverable: `docs/research/worktree-isolation.md` following the standard Research structure (Summary, Findings, Recommendation, Open Questions, Sources). Cover: whether this round-trip is enough of a bottleneck to justify git worktree isolation with a mechanism for shipping a pre-approved subset of gitignored secrets into an agent's workspace deliberately; whether this fits our sequential (non-parallel) execution model or is only useful if we ever revisit parallelism. Explicitly mark this Recommendation, not Decision — this is a "watch it, don't build it yet unless the bottleneck becomes real" candidate, not something to implement speculatively.

## Decisions (human only)

- [ ] #7 **Resolve whether nightlight needs npm/package distribution at all**
  This blocks further naming work. nightlight is used only by us, across repos we own — it isn't something anyone else installs. Options on the table: skip packaging entirely and keep nightlight as files in a personal dotfiles-style repo (current de facto state); package it as a Claude Code plugin/skill for "install once, use everywhere" convenience across machines; or proceed with an npm package under a scoped name (`@c0d3ster/nightlight` or similar) despite the unscoped name being taken. Requires your input — not an agent judgment call.

- [ ] #8 **Decide whether to layer `--permission-mode auto` under the existing allowlist, or hold at `acceptEdits`**
  Depends on the Verify task above confirming eligibility. If eligible, decide whether to add `auto` mode as an additional safety layer underneath the existing `.claude/settings.json` allow/deny list, or hold at current `acceptEdits` behavior. Note: do not adopt a `bypassPermissions`-style fallback under any circumstance — if `auto` isn't available, staying on `acceptEdits` plus the explicit list is the safer posture.

## Discovered
