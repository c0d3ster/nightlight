---
name: discover-tasks
description: Mines a target repo's own memory (and, with --scan, its codebase) for task candidates and proposes additions to its TASKS.md § Discovered. Run before /plan-tasks when task ideas have accumulated from direct work sessions in the target repo.
disable-model-invocation: true
---

A target repo is attached via --add-dir. Two independent sourcing phases: memory-mining (always runs) and repo-scanning (only with `--scan`).

## Multi-repo mode

Determine this from the attached directory's structure, never by assumption: does it have a `.git` at its own root?

- Yes: it's a single target repo. Phases 1–4 below apply directly, exactly as written — this is today's behavior, unchanged.
- No, but its immediate subdirectories do: the attached directory is `PROJECT_REPOS_DIR` itself, and the repo set is those subdirectories. Run this flow instead of a single Phases 1–4 pass:
  1. Announce: "Found N repo(s) under `<dir>`."
  2. Dispatch one `general-purpose` agent per repo — all in a single message, foreground, batched in groups of ~8 if there are more than that — each told to run Phase 1 + Phase 2 steps 1–3 for its one assigned repo (absolute path stated explicitly) and report back its candidate list (task text, rationale, source) — report only, never ask, never write. Use `general-purpose`, not `Plan`: a dispatch needs Agent-tool access itself to reach `task-scout` when `--scan` is passed, and `Plan`-type agents don't have that.
  3. Once every dispatch returns, go through repos in the order they were listed. For each one: run Phase 2 step 4 (present its candidates, get my approval), then immediately Phase 3 (write) and Phase 4 (finalize) for that repo, before moving to the next.

Announce each phase to me in one line before starting it.

## Phase 1: locate memory

1. Announce: "Scanning `<repo>`'s memory for task candidates."
2. Determine self-targeting by comparing paths, never by assumption: get the target repo's absolute path (from --add-dir) and this session's own primary working directory (from environment info). Self-targeting applies ONLY if these two paths are the same directory — i.e. nightlight is discovering on itself. State the comparison result explicitly before proceeding (e.g. "target repo == primary dir, this is self-targeting" or "target repo != primary dir, treating as a separate repo").
3. Self-targeting confirmed: the target repo's memory is just this session's own memory, already loaded — use its MEMORY.md directly, skip step 4.
4. Not self-targeting: find the entry in `~/.claude/projects/` whose name matches the target repo's absolute path (`:` and path separators → `-`) — that's its own memory folder, distinct from nightlight's since memory is scoped to the session's primary directory, not add-dir targets. Confirm against the real listing rather than assuming the encoding.
5. No matching folder, or no MEMORY.md: say so plainly, skip to Phase 2 step 3 (repo-scan), or exit if `--scan` wasn't passed either.

## Phase 2: propose candidates

1. Read the target repo's MEMORY.md and its indexed files. Pull only entries reading as concrete, discrete work — most `project`-type memories are context, not tasks.
2. Cross-reference against the target repo's TASKS.md (open items) and `docs/tasks-archive/*.md` (completed). Drop anything already covered.
3. `--scan` passed: dispatch the `task-scout` agent (foreground) for codebase-derived candidates. **Not built yet** — if missing, say so and skip this part rather than failing the run.
4. Announce: "Found N candidate(s) from memory[, M from repo scan]." Present the full list — task text, one-line rationale, source — for my approval. Write nothing until I approve; accept/reject individually.

## Phase 3: write approved candidates

1. Announce: "Writing N approved item(s) to TASKS.md."
2. Append each approved candidate under `## Discovered` (create if absent): one-line description + source. No `#<n>` or `[stack]` — that's `/plan-tasks`'s job.
3. Memory-sourced items: delete the source memory file and its MEMORY.md line. Leave rejected candidates untouched.
4. Announce: "Done — N item(s) added to TASKS.md § Discovered, N memory file(s) cleared."

## Phase 4: finalize

Uncommitted content in the target repo's working tree is dangerous — lost work, or silently swept into unrelated commits. Don't leave the TASKS.md edit uncommitted. Once written:

1. Confirm discovery is done and I want these additions committed + PR'd. Don't proceed without an explicit yes — I may want another discover pass first.
2. Resolve the default branch: `git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to local `main` then `master` — same resolution `overnight.sh`'s `default_branch()` uses.
3. Target repo's current branch (`git -C <repo> branch --show-current`) doesn't match that default? STOP — don't branch, commit, or PR. Tell me which branch it's actually on and that the edit is staying uncommitted; committing here would silently fold it into unrelated in-progress work. I'll switch branches or handle it myself, then re-run finalize.
4. Matches: pull latest, branch off it as `chore/tasks-discover-<YYYY-MM-DD>` (append `-2`, `-3`... if taken locally or on the remote).
5. Stage only what this phase touched — TASKS.md and any memory files deleted in step 3. Never `git add -A`; the working tree may hold unrelated uncommitted work that isn't yours to commit.
6. Commit as `chore(tasks): discover N candidate task(s)`, body listing each item and its memory source.
7. Push, open a PR (`gh pr create`) targeting the default branch — title matches the commit, body summarizes the additions.
8. Report the PR URL.
9. Merge it: `gh pr merge <branch-name> --squash --delete-branch`, using the exact branch name from step 4 (not a PR number — that's what the scoped `chore/tasks-discover-*` merge permission matches against). This is safe specifically because every item going in was already explicitly approved by me in Phase 2 step 4 — the merge completes something already signed off on, it doesn't approve anything new.
10. Merge command fails (e.g. branch protection requires a review)? Report the failure plainly and leave the PR open. Don't retry, don't force, don't fall back to raw `git merge` — that stays denied regardless.
11. Merge succeeds: `git -C <repo> checkout` the default branch and pull latest, so the working tree's TASKS.md reflects the merge before this session ends — that's what lets a later `/plan-tasks` or `overnight.sh` run see these additions without anyone merging by hand.

Do not implement any code in this session. Do not touch `docs/tasks-archive/` or `docs/nightlight-meta.json`.
