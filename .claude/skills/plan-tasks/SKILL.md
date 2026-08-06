---
name: plan-tasks
description: Plans and stack-annotates a target repo's TASKS.md. Use when starting a planning session to break down Agent-Ready tasks, assign [stack] annotations, and flag prerequisites before an overnight run.
disable-model-invocation: true
---

A target repo is attached via --add-dir. Read its TASKS.md, CLAUDE.md, and docs/nightlight-meta.json (if present — `nextTaskNumber` is the next number to assign; treat a missing file as `nextTaskNumber: 1`).

## Multi-repo mode

More than one repo attached via --add-dir (`plan.sh`'s no-arg mode passes one `--add-dir` per repo that has open, unchecked `TASKS.md` work): read TASKS.md/CLAUDE.md/docs/nightlight-meta.json for every attached repo, keeping each repo's state separate — `#<n>` numbering, `[stack]` names, and `nextTaskNumber` are all per-repo, never shared or cross-referenced across repos. Investigate (parallel) below dispatches across every attached repo's items in one combined batch; Synthesize then runs once per repo, in the order the repos were attached, each with its own approval, write, and finalize before moving to the next. One repo attached: today's flow, unchanged.

`## Discovered` holds raw, un-triaged candidates (no `#<n>`, no `[stack]`) — they're in scope below alongside native Agent-Ready/Verify/Research/Decisions items, for every attached repo.

## Investigate (parallel)

Every unchecked item across every attached repo (including Discovered ones) gets its own investigation — dispatch one `Plan`-type agent per item, all as parallel foreground tool calls in a single message, regardless of which repo it belongs to. Never investigate items one at a time in the main thread; that's the slow path this phase replaces. If there are more than ~8 items total, dispatch in batches of that size rather than serially one-by-one.

Each dispatch is self-contained (the agent has no memory of this session) and must state: the item's exact text, its repo's absolute path, and that it should read that repo's CLAUDE.md itself for conventions. Ask each agent to report back — never implement — with:

1. For a Discovered item: which section it actually belongs in — Agent-Ready (the common case), Verify, Research, or Decisions (flag for my judgment).
2. A sub-task breakdown with file-level hints and any missing acceptance criteria.
3. Missing prerequisites (fixtures, env vars, dependencies) as candidate NEEDS HUMAN annotations.
4. The concrete files/schemas/exports/components it expects to touch — needed for the cross-item overlap analysis below.

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
