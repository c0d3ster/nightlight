---
name: plan-tasks
description: Plans and stack-annotates a target repo's TASKS.md. Use when starting a planning session to break down Agent-Ready tasks, assign [stack] annotations, and flag prerequisites before an overnight run.
disable-model-invocation: true
---

A target repo is attached via --add-dir. Read its TASKS.md, CLAUDE.md, and docs/nightlight-meta.json (if present — `nextTaskNumber` is the next number to assign; treat a missing file as `nextTaskNumber: 1`).

## Multi-repo mode

More than one repo attached via --add-dir (`plan.sh`'s no-arg mode passes one `--add-dir` per repo that has open, unchecked `TASKS.md` work): read TASKS.md/CLAUDE.md/docs/nightlight-meta.json for every attached repo, keeping each repo's state separate — `#<n>` numbering, `[stack]` names, and `nextTaskNumber` are all per-repo, never shared or cross-referenced across repos. Investigate (parallel) below dispatches across every attached repo's items in one combined batch; Synthesize then runs once per repo, in the order the repos were attached, each with its own approval, write, and finalize before moving to the next. One repo attached: today's flow, unchanged.

`## Discovered` holds raw, un-triaged candidates (no `#<n>`, no `[stack]`) — they're in scope below alongside native Agent-Ready/Verify/Research/Decisions items, for every attached repo.

## Task source mode

Per attached repo, read `taskSource` from its `docs/nightlight-meta.json` (missing file or field = `local`). Run `source lib/task-source.sh && load_task_source <repo>` from the nightlight checkout (it sets `TASK_SOURCE` and loads the `ts_*` functions); a load error means skip that repo and say why. Modes are per repo, so one session can mix them.

- `local`: everything in this file applies exactly as written.
- `github` (remote): the tracker replaces TASKS.md and `nightlight-meta.json`'s numbering. Never read, edit, or commit TASKS.md or open a chore PR for this repo. Deltas, applied where the named step appears below:
  - Items: the open issues labeled `nl:discovered` (`gh issue list --label nl:discovered --state open`), plus any open `nl:*`-sectioned issues I name. An item's text is the issue title and body, its id is the issue number.
  - Investigate: unchanged. The prompt is the issue's text and number plus the repo path; the agent needs no source-specific logic.
  - Synthesize step 2 (assign `#<n>`): skipped, the issue number is the id. Stack names are still per repo.
  - Synthesize write: after approval, create any missing section or `nl:stack:<name>` label (`gh` rejects labels that don't exist: `gh label create <name> --repo <repo>`), then apply labels with `gh issue edit <n> --add-label <section>,nl:stack:<name> --remove-label nl:discovered` (labels come from the repo's `labels` block, defaults `nl:agent-ready`/`nl:verify`/`nl:research`/`nl:decision`, stack prefix `nl:stack:`). Breakdowns go in as an issue comment (`gh issue comment`). Position: issue number is the order, so skip the position question.
  - Finalize: skipped entirely. The write landed on approval; report the issue URLs instead.

## Dedupe (every mode)

Before Investigate, for each Discovered item run `ts_find_related <repo> "<short distinctive phrase from the item>"` (output: state, id, title or file:line). Local matches by fixed string, so keep the phrase short. Ignore a match that is the item itself. For matches that look implemented, confirm with a cheap code check: dispatch `task-scout` in verify mode (prompt: the item text, the related items with ids and states, and the repo path), in parallel with the other lookups. Then show every match in the proposal with its id, state (open, closed, archived, or looks implemented) and a one-line reason, and ask per match: skip the item, reopen the closed one, link the item to it as a follow-up, or create it anyway. Never drop an item silently. Items with no matches proceed as normal.

## Investigate (parallel)

Every unchecked item across every attached repo (including Discovered ones) gets its own investigation — dispatch one `task-investigator` agent per item, all as parallel foreground tool calls in a single message, regardless of which repo it belongs to. Never investigate items one at a time in the main thread; that's the slow path this phase replaces. If there are more than ~8 items total, dispatch in batches of that size rather than serially one-by-one.

Each dispatch is self-contained (the agent has no memory of this session): its prompt is just the item's exact text and its repo's absolute path. The agent file defines the standing instructions and the four-part report (section, breakdown, prerequisites, touch-points); never implement.

## Synthesize

Once every dispatched investigation has returned, process repos one at a time, in the order they were attached (single-repo mode: just the one). For each repo:

1. Cross-reference reported touch-points and dependencies across that repo's items only — stacks and numbering never cross repos: share `[stack: <name>]`, in execution order, if they depend on each other or touch the same files; independent items get `[stack: solo]`. When in doubt, stack.
2. Assign each item a stable `#<n>`, starting from that repo's own `nextTaskNumber` and incrementing per item, in write order.
3. Propose where each item lands in its target section's existing list — default to the bottom, but ask me explicitly where I want each one; I may want something worked first (e.g. a quick bug fix ahead of a bigger feature).

Present the full proposal for my approval BEFORE writing anything — triage decisions (for former Discovered items), breakdowns/numbers/stack tags, and proposed position per item. After I approve:

- Write the breakdowns, `#<n>` numbers, and `[stack]` tags into that repo's TASKS.md at the approved position — every checkbox line gets its number right after the checkbox, before the stack tag (e.g. `- [ ] #48 [stack: auth] Add rate limiting to login endpoint`).
- Remove triaged items from that repo's `## Discovered`.
- Update that repo's `docs/nightlight-meta.json`'s `nextTaskNumber` to one past the highest number assigned (create it with `nextTaskNumber`, `tasksCompleted: 0`, `tasksBlocked: 0` if missing).

Then immediately run Finalize (below) for that repo before starting the next repo's Synthesize.

## Finalize

Uncommitted content in the target repo's working tree is dangerous — lost work, or silently swept into unrelated commits. Don't leave the TASKS.md/nightlight-meta.json edits uncommitted. Once written, for this repo:

1. Confirm planning is done and I want these changes committed + PR'd. Don't proceed without an explicit yes.
2. Resolve the default branch: `git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to local `main` then `master` — same resolution `overnight.sh`'s `default_branch()` uses.
3. Target repo's current branch (`git -C <repo> branch --show-current`) doesn't match that default? STOP — don't branch, commit, or PR. Tell me which branch it's actually on and that the changes are staying uncommitted; committing here would silently fold them into unrelated in-progress work. I'll switch branches or handle it myself, then re-run finalize.
4. Matches: pull latest, branch off it as `chore/tasks-plan-<YYYY-MM-DD>` (append `-2`, `-3`... if taken locally or on the remote).
5. Stage only TASKS.md and `docs/nightlight-meta.json`. Never `git add -A`; the working tree may hold unrelated uncommitted work that isn't yours to commit.
6. Commit as `chore(tasks): number and stack N task(s)`, body listing the task numbers and stack names assigned.
7. Push, open a PR (`gh pr create`) targeting the default branch — title matches the commit, body summarizes the assignments.
8. Report the PR URL.
9. Merge it: `gh pr merge <branch-name> --squash --delete-branch`, using the exact branch name from step 4 (not a PR number — that's what the scoped `chore/tasks-plan-*` merge permission matches against). This is safe specifically because the breakdown/numbering/stacking going in was already explicitly approved by me in Synthesize — the merge completes something already signed off on, it doesn't approve anything new.
10. Merge command fails (e.g. branch protection requires a review)? Report the failure plainly and leave the PR open. Don't retry, don't force, don't fall back to raw `git merge` — that stays denied regardless.
11. Merge succeeds: `git -C <repo> checkout` the default branch and pull latest, so the working tree's TASKS.md reflects the merge before this repo's finalize is done — that's what lets a later `overnight.sh` run see the numbering/stacking without anyone merging by hand.

Do not implement any code in this session.
