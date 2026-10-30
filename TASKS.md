# TASKS.md — nightlight

This is nightlight working on itself: the target repo for these tasks is the nightlight repo, not Modernizer/Fractaleyez/c0d3ster.

---

## Agent-Ready

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

- Map non-solo stacks to GitHub milestones in remote (github) mode: add optional `ts_ensure_group(stack, description)` / `ts_close_group(stack)` to the task-source contract (local no-op), have `/plan-tasks` create the milestone from the PRD phase goal and set it on each issue, have housekeeping close it when the stack is finished (reopen on resume), and add a narrow `gh api repos/*/milestones*` allow entry. The `nl:stack:<name>` label stays authoritative for dispatch. Found in design discussion on `docs/plans/multi-task-source.md` (2.6) and `lib/task-source-github.sh`.

