# TASKS.md — nightlight

This is nightlight working on itself: the target repo for these tasks is the nightlight repo, not Modernizer/Fractaleyez/c0d3ster.

---

## Agent-Ready

- [ ] #13 [stack: task-sources] **Extract `lib/task-source-local.sh` from `overnight.sh`**
  Plan: `docs/plans/multi-task-source.md` Phase 1.2. Move `split_tasks()`, the `#<n>`/`[stack]` regexes, and the open-work gate (`grep -Eq '^\s*- \[ \]'`) behind the `ts_is_eligible` / `ts_list_tasks` / `ts_task_result_re` contract in a new `lib/task-source-local.sh`, sourced by `run_repo()`. Zero behavior change. Heads-up: `#4`, `#28`, and `#29` (stack `core-loop`) also edit `overnight.sh` (`run_repo()`, `build_task_prompt()`, `build_housekeeping_prompt()`), CLAUDE.md, and README.md. Check `git log` on main for them first and build on whatever has merged; if they are unmerged, expect conflicts and rebase the extraction around them rather than reverting their changes.

  Acceptance criteria: the local regex is still exactly `#([0-9]+)`; `run_repo()` sources the module; a local dry run produces identical task records and dispatch order to before the extraction; the module also exposes `ts_find_related` (open TASKS.md items plus `docs/tasks-archive/*.md`), the logic `/discover-tasks` runs inline today (plan 1.2, 1.6).

- [ ] #14 [stack: task-sources] **Generalize `TASK_RESULT` matching and `--stop-after` to opaque task ids**
  Plan Phase 1.3, 1.4. Replace the hardcoded `#$num` at `overnight.sh`'s `TASK_RESULT` match sites (prompt contract, `task_result_re`, the two `sed` extractions) with `ts_task_result_re`. Add `TS_NUMERIC_IDS=1|0` to each module; `--stop-after` errors clearly when the active module sets 0 instead of silently no-op'ing.

  Acceptance criteria: local mode still emits and matches `TASK_RESULT: #<n> ...`; the id is treated as an opaque string everywhere except the `--stop-after` check. Depends on `#13`.

- [ ] #15 [stack: task-sources] **Read `taskSource` config and select the module in `run_repo()`**
  Plan Phase 1.1. Read `taskSource` (`local` default, `github`, `linear`) and the `github.repo` / `linear.teamId` blocks plus the optional `labels` block from the target repo's `docs/nightlight-meta.json`; `run_repo()` sources `lib/task-source-<name>.sh` accordingly. Missing file or field means `local`. Unknown values error clearly.

  Acceptance criteria: repos with no `taskSource` behave exactly as today; an unknown `taskSource` fails with a clear message. Depends on `#14`.

- [ ] #16 [stack: task-sources] **Add `lib/task-source-github.sh`**
  Plan Phase 2.2, 2.4. `ts_list_tasks` runs `gh issue list --json number,title,body,labels,author,authorAssociation,comments,createdAt` once per section label (`nl:agent-ready`, `nl:verify`, `nl:research`), merges, sorts by issue number, skips `nl:blocked` / `nl:needs-human`, extracts the stack from `nl:stack:*` (no label inherits the previous task's stack, `nl:stack:solo` is solo). `blockfile` is synthesized from title, body, and comments by `OWNER`/`MEMBER`/`COLLABORATOR` only. Repo defaults to `origin`, overridable by `github.repo`. `TS_NUMERIC_IDS=1`, ids are `#<n>`. `ts_is_eligible` shares the same query.

  Acceptance criteria: output matches the tab-separated `id\tstack\tblockfile` shape; issues without an `nl:*` section label are never returned; non-collaborator comments are absent from the block; one API query per run feeds both gate and loop; `ts_find_related` searches open and closed issues via `gh issue list --state all --search`. Also add a github-mode branch to `build_task_prompt` (plan 2.3): tell the agent its issue number and to read detail with `gh issue view <n> --comments`, reference the issue as `` `#<n>` `` in backticks in the PR body, never use `Closes #n`, and never set status labels itself. Local-mode prompts stay byte-for-byte unchanged. Depends on `#15`.

- [ ] #17 [stack: task-sources] **Route `plan.sh` / `discover.sh` eligibility through the task-source module**
  Plan Phase 1 (eligibility). Replace the inline `grep -Eq '^\s*- \[ \]'` gate in `plan.sh` with `ts_is_eligible` for the repo's configured source. `discover.sh`'s no-arg mode has no gate today and stays that way; repo classification for remote sources happens inside the skill.

  Acceptance criteria: `plan.sh` no-arg mode still skips local repos with no open tasks and attaches the rest exactly as before; a github-mode repo with no labeled open issues is skipped. Depends on `#16`.

- [ ] #18 [stack: task-sources] **Mode detection in `/plan-tasks` and `/discover-tasks` skills**
  Plan Phase 1.6. Add a preamble reading `taskSource` per attached repo. Remote mode, discover: Phase 3 creates issues labeled `nl:discovered` via `gh issue create`. Remote mode, plan: skip the "assign `#<n>`" step and apply section/stack labels via `gh issue edit` instead. Phase 4 / Finalize is skipped in remote mode. Local mode is unchanged. Remote-mode `/plan-tasks` still dispatches `task-investigator` per item (its prompt is the issue's text and number plus the repo path; the agent needs no source-specific logic), and the dedupe step's code check dispatches `task-scout` in verify mode rather than adding logic to the skill.

  Acceptance criteria: both skill files document both modes; local-mode text is untouched; remote mode never edits TASKS.md or opens a chore PR. Both skills, in every mode, run the plan 1.6 dedupe step (its cheap code check dispatches `task-scout` in verify mode, see `#35`): `ts_find_related` per candidate, a cheap code check for matches that look implemented, every match shown with its state, per-match choice (skip, reopen, link as follow-up, create anyway), and no silent drops (`/plan-tasks` gains dedupe it lacks today). Depends on `#16`.

- [ ] #19 [stack: task-sources] **Remote housekeeping path (GitHub)**
  Plan Phase 2.5. After confirming real PR/branch state: close merged tasks' issues (`--reason completed`) with a PR-link comment; add `nl:blocked` with the reason comment for blocked tasks; add `nl:needs-human` with exact steps for needs-human tasks, and close those issues once their PR merges; flag (never silently resolve) issues with contradictory labels. `tasksCompleted` / `tasksBlocked` in `docs/nightlight-meta.json` still go through the small housekeeping commit + PR. Update `build_housekeeping_prompt` accordingly, selected by `taskSource`. Heads-up: `#29` (stack `core-loop`) also rewrites parts of `build_housekeeping_prompt()` and the CLAUDE.md housekeeping bullets (stack-notes file removal); build on it if merged, and keep its local-mode wording intact.

  Acceptance criteria: local-mode housekeeping prompt is unchanged; in github mode no TASKS.md or archive file is written; issues are closed only after their PR merged. Depends on `#16`.

- [ ] #20 [stack: task-sources] **GitHub mode permissions and docs**
  Plan Phase 1.8, 2.3. Add narrow `.claude/settings.json` allow entries (`gh issue view/list/comment/create/edit`) and denies (`gh issue delete`, `gh repo delete`). Document GitHub mode alongside local mode in CLAUDE.md (Task numbering, TASKS.md maintenance, Section semantics) without changing local-mode language, and add a README opt-in section (`taskSource`, `github.repo`, labels, the public-repo label-permission caveat from the plan's 2.4).

  Acceptance criteria: no blanket `gh` or MCP allow; README states local `TASKS.md` stays the default. Depends on `#19`.

- [ ] #32 [stack: task-sources] **`pnpm migrate`: move a repo from local `TASKS.md` to GitHub issues**
  Source: 2026-10-19 planning session. `/discover-tasks` only finds new candidates; it never reviews existing issues for staleness, and nothing pushes `TASKS.md` items into issues. Add `migrate.sh` (`pnpm migrate <repo> --to github`, wired in `package.json` like `plan`/`discover`) that launches an approval-gated skill, `.claude/skills/migrate-tasks/SKILL.md`, modeled on the other two skills. Steps: (1) for each open `TASKS.md` item, run `ts_find_related` against existing issues (open and closed) and ask per match: skip, link, or create anyway; (2) create issues with `nl:<section>` and `nl:stack:<name>` labels, mapping `[!]` to `nl:blocked` and `[/]` to `nl:needs-human`, with the original `#<n>` and a note in the body since issue numbers differ; (3) review each existing open issue that has no `nl:*` label against the code and recent merges (dispatch `task-scout` in verify mode per issue for the code check), then propose per issue: label it into a section, close it as stale (with a comment), or leave it; nothing is closed or edited without per-item approval; (4) set `taskSource: "github"` (plus `github.repo` if the backlog lives elsewhere) in `docs/nightlight-meta.json` via the usual small `chore/` PR, and move the old `TASKS.md` open items to `docs/tasks-archive/` rather than deleting them. Local-to-GitHub only; Linear and the reverse direction are out of scope.

  Acceptance criteria: re-running is idempotent (items already migrated are matched by `ts_find_related`, not duplicated); no issue is created, closed, or relabeled without explicit approval; every open `TASKS.md` item ends up as an issue or is explicitly skipped by the human; the old `TASKS.md` content is preserved in the archive; the target repo's `taskSource` flips only after the issues exist. Depends on `#20`.

- [ ] #21 [stack: task-sources] **GitHub mode dry run against a sandbox repo**
  Plan Phase 2 verification. NEEDS HUMAN prerequisite: a throwaway GitHub repo with the `nl:*` labels and a few seeded issues, path given by the human. Run listing, dispatch one task end to end, and housekeep. Report as needs-human if no sandbox repo is available.

  Acceptance criteria: `ts_list_tasks` returns issues in number order with correct stacks; a stranger-labeled or unlabeled issue is not dispatched; the issue closes only after its PR merges; `--stop-after` works. Depends on `#32`. Also exercise `pnpm migrate` here, dry-run style, against the existing issues. Note: the human is running this against fractaleyez (a real repo with existing, out-of-date, overlapping GitHub issues) instead of a sandbox. Existing issues have no `nl:*` labels, so none may be dispatched; the human labels a few to dispatch. Do not close, edit, or relabel any issue not explicitly named by the human.

- [ ] #22 [stack: task-sources] **Linear OAuth-persistence gate and MCP tool inventory**
  Plan Phase 3.6, 3.3. Independent of the GitHub dry run (`#21`); stack order only. NEEDS HUMAN prerequisite: the human has run `claude mcp add` for Linear's hosted MCP server. Verify the OAuth session survives many independent unattended `claude -p` launches without re-prompting, and record the real Linear MCP tool names and params. Deliverable: `docs/research/linear-mcp.md` (Summary, Findings, Recommendation, Open Questions, Sources). Docs only. If auth lapses, say so plainly and recommend against unattended Linear mode.

  Acceptance criteria: the doc states pass/fail for persistence with the evidence, and lists the actual tool names later tasks must use. Depends on `#21`.

- [ ] #23 [stack: task-sources] **Linear: `.mcp.json` and `LINEAR_API_KEY` resolver**
  Plan Phase 3.2, 3.3. Add a checked-in `.mcp.json` registering `https://mcp.linear.app/mcp`. Add a resolver in the wrapper scripts that extracts `LINEAR_API_KEY` from the target repo's `.env` via a targeted `grep '^LINEAR_API_KEY='` first, falling back to nightlight's `.env`. Never source the target's `.env` wholesale.

  Acceptance criteria: resolver works with the key in either location; the agent-side `Read(.env)` deny is untouched. Depends on `#22`.

- [ ] #24 [stack: task-sources] **Add `lib/task-source-linear.sh`**
  Plan Phase 3.3, 3.4. `ts_list_tasks` / `ts_is_eligible` via `curl` + `jq` against `https://api.linear.app/graphql`; ids are Linear identifiers (`ENG-142`); order within a stack is creation time; skip `nl:blocked` / `nl:needs-human`; `TS_NUMERIC_IDS=0`; `ts_task_result_re` matches the bare identifier.

  Acceptance criteria: same tab-separated record shape as the other modules; `--stop-after` errors against a Linear-mode repo; one query feeds gate and loop; `ts_find_related` searches open and closed issues via the API. Depends on `#23`.

- [ ] #25 [stack: task-sources] **Linear housekeeping and skill write paths via MCP**
  Plan Phase 3.4. Housekeeping and the remote branches of `/plan-tasks` and `/discover-tasks` use the Linear MCP tools confirmed in `#22`: transition labels, move to Done only if the PR merged, post a PR-link comment, create `nl:discovered` issues. Reuse the remote-mode structure from `#18` and `#19`; only the write path differs.

  Acceptance criteria: no `gh issue` calls in Linear mode; Finalize skipped; meta.json commit path unchanged; the plan 1.6 dedupe flow works in Linear mode (the code check reuses `task-scout` verify mode, no Linear-specific variant), with "reopen" and "link as follow-up" done through MCP. Depends on `#24`.

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

- [ ] Count `nl:discovered` issues in the GitHub eligibility gate. `ts_is_eligible` only fetches the section labels, so a repo whose only open items are `nl:discovered` is skipped by `plan.sh` and `overnight.sh`; local mode counts `## Discovered` lines. Found live-testing #65/#66 on Fractaleyez, 2026-10-26.
- [ ] Surface `gh` failures in `lib/task-source-github.sh` instead of reporting "no open tasks". `plan.sh` sends `ts_is_eligible` stderr to /dev/null and treats any failure as ineligible, so a bad `github.repo`, auth, or network error looks like an empty backlog. Found live-testing #66, 2026-10-26.
- [ ] Priority labels for the GitHub source. `nl:priority:high` / `nl:priority:low` (names overridable in the `labels` block) sort within the dispatch order; issues without a priority label fall back to ascending issue number. Adopted pre-existing issues default to running before new ones, so migration needs a way to set that default per repo. Dispatch order is issue number ascending today (plan doc, Phase 2), so old issues already run first by accident. Decided 2026-10-26.
- [ ] Adopt existing GitHub issues without a `TASKS.md`. `pnpm migrate` is local-to-GitHub only, but its step 3 (review unlabeled open issues with `task-scout` verify, then per-item label, close as stale, or leave) should also run standalone for repos already on issues. Still opt-in and approval-gated: never bulk-label a repo's issues automatically. Decided 2026-10-26.
- [ ] Sanitize the phrase in the GitHub `ts_find_related`. It goes straight into `gh issue list --search`, so `word:word` tokens act as GitHub search qualifiers (`user:admin` matched unrelated issues) and a quoted phrase matched nothing. Strip or escape qualifier syntax before searching. Found live-testing #67 on Fractaleyez, 2026-10-26.
- [ ] Consolidate missing-label handling into one `ts_gh_ensure_labels` helper in `lib/task-source-github.sh`. `gh` rejects labels that don't exist, and the "create it first" instruction is now copied into the discover skill, the plan skill, and the housekeeping prompt (and migrate has its own). One idempotent helper that creates the `nl:*` labels from the `labels` config would replace all of them. Found live-testing #67/#68, 2026-10-26.
