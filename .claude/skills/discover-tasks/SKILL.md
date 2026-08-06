---
name: discover-tasks
description: Mines a target repo's own memory (and, with --scan, its codebase) for task candidates and proposes additions to its TASKS.md § Discovered. Run before /plan-tasks when task ideas have accumulated from direct work sessions in the target repo.
disable-model-invocation: true
---

A target repo is attached via --add-dir (self-targeting: nightlight discovering on itself — --add-dir then resolves to this session's own primary directory). Two independent sourcing phases: memory-mining (always runs) and repo-scanning (only with `--scan`).

Announce each phase to me in one line before starting it.

## Phase 1: locate memory

1. Announce: "Scanning `<repo>`'s memory for task candidates."
2. Self-targeting: the target repo's memory is just this session's own memory, already loaded — use its MEMORY.md directly, skip step 3.
3. Otherwise: find the entry in `~/.claude/projects/` whose name matches the target repo's absolute path (`:` and path separators → `-`) — that's its own memory folder, distinct from nightlight's since memory is scoped to the session's primary directory, not add-dir targets. Confirm against the real listing rather than assuming the encoding.
4. No matching folder, or no MEMORY.md: say so plainly, skip to Phase 2 step 3 (repo-scan), or exit if `--scan` wasn't passed either.

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

Do not implement any code in this session. Do not touch `docs/tasks-archive/` or `docs/nightlight-meta.json`.
