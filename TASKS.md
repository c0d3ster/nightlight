# TASKS.md — nightlight

This is nightlight working on itself: the target repo for these tasks is the nightlight repo, not Modernizer/Fractaleyez/c0d3ster.

---

## Agent-Ready

- [ ] #1 [stack: solo] **Add retry-before-block rule to CLAUDE.md**
  Right now, any task failure (a flaky test, a wrong first approach, a transient tool hiccup) goes straight to "annotate blocked, skip, move on." Not every failure is a genuine blocker — some just need a second attempt with the diagnostic info from the first one. Add a distinction to the Task breakdown rules section of CLAUDE.md between retry-worthy failures (implementation attempted, tests or acceptance criteria failed, nothing indicates the task is ambiguous or externally blocked — retry once from a clean state, discarding the failed attempt's commits, before falling back to blocked) and genuine blocks (ambiguity, missing prerequisite, cross-stack dependency discovered mid-task, human-only decision — no retry, annotate and move on immediately, per existing rules). Acceptance criteria: CLAUDE.md's "Task breakdown rules" section has a new subsection distinguishing the two failure types with the retry-once behavior spelled out; existing "never guess on judgment calls" language for genuine blocks is preserved unchanged.

- [ ] #2 [stack: core-loop] **Design and implement fresh-subprocess-per-task execution model**
  `overnight.sh` currently runs one continuous `claude -p` session across all of a repo's TASKS.md items, so context accumulates across tasks with no clean boundary. Restructure it to loop over unchecked TASKS.md items and invoke one `claude -p` subprocess per task, each starting clean.

  Stacked tasks still need predecessor context. Maintain `docs/stack-notes/<stack-name>.md`: created by the first task in a stack, appended (never rewritten) by each subsequent one — task name, key decisions, interfaces/exports created, any deviation from acceptance criteria. Feed a stacked task's prompt from this file instead of a raw diff/commit dump. Solo tasks get no stack-notes file.

  Acceptance criteria: per-task dispatch loop in `overnight.sh`; stack-notes created/appended per above; stacked-task prompts read from stack-notes, not raw diffs; housekeeping still runs once at the end of the full loop (optionally folding a completed stack's notes into that day's archive entry).

  NEEDS HUMAN: before treating this as default, do a supervised trial run on a low-stakes repo — `--limit 2` across at least two different stacks (e.g. `pnpm overnight <repo> --limit 2 --stack <name>`) — confirming dispatch and stack-notes handoff work as intended. Don't skip this trial.

- [ ] #9 [stack: core-loop] **Add TASKS.md status glyphs and auto-archive NEEDS HUMAN tasks on PR merge**
  Right now blocked and NEEDS HUMAN tasks are only distinguishable by reading each line's free-text annotation, and NEEDS HUMAN tasks stay in TASKS.md indefinitely with no defined path back to archive once you've completed the manual step and merged the PR. Replace `- [ ]` with distinct glyphs written only by housekeeping (preserving its single-writer role): `[!]` for blocked, `[/]` for NEEDS HUMAN. Each housekeeping run also checks every `[/]`-annotated task's PR merge state (`gh pr view <PR> --json state,mergedAt`); if merged, archive it as completed (task number, text, PR number, note that it required a human step) and remove it from TASKS.md — no manual edit required from you beyond merging the PR.

  Acceptance criteria: CLAUDE.md's "Section semantics" and "TASKS.md maintenance" sections document `[ ]`/`[!]`/`[/]` semantics; housekeeping sets `[!]`/`[/]` when annotating blocked/NEEDS HUMAN tasks; housekeeping checks merge state of every `[/]` task's PR each run and auto-archives any now-merged ones.

- [ ] #10 [stack: core-loop] **Interrupted-task detection and retry via git branch scan**
  Once tasks run as separate subprocesses (see task #2), a session interrupted mid-task (window closed, machine slept) needs to be detected on the next run without writing anything to TASKS.md mid-session, since only housekeeping may write there. Give each task branch's first commit a `Task: #<n>` trailer. At the start of a session, scan local branches for that trailer against every currently-open (`[ ]`) task; if a matching branch exists with no open PR (`gh pr list`), housekeeping never ran for it — treat it as an interrupted attempt: discard the branch and retry the task once from a clean state, per task #1's retry-once rule. If a matching branch has an open PR, leave it alone; that's just "done, housekeeping hasn't run yet," not interrupted.

  Note: this reuses task #1's retry-once behavior, which lives in a different (solo) stack. If #1 hasn't merged to main by the time this task is reached, treat that as a cross-stack dependency per existing rules (stop, annotate blocked, move on) rather than reimplementing the rule inline.

  Acceptance criteria: task branches' first commit includes a `Task: #<n>` trailer; session start includes a scan step that identifies orphaned branches (matching trailer, no open PR) for open tasks; orphaned branches are discarded and their task retried once from a clean state; branches with an open PR are left untouched. Depends on task #2.

- [ ] #4 [stack: core-loop] **Split overnight logs per task**
  Once execution is subprocess-per-task, have each subprocess write its own log file (tagged with task slug and timestamp) in addition to or instead of the single combined tee currently written to `~/overnight-logs/<repo>-<date>.log`. A combined log makes it hard to isolate "what happened on task 6" without scrolling past everything before it. Acceptance criteria: each task's `claude -p` subprocess output lands in its own file under `~/overnight-logs/<repo>-<date>/<task-slug>-<timestamp>.log` (or equivalent); a combined summary log or the terminal output still gives an overview of the whole run without needing to open every per-task file. Depends on the subprocess-per-task task above.

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
