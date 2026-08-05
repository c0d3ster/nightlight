---
name: discover-tasks
description: Mines a target repo's own memory (and, with --scan, its codebase) for task candidates and proposes additions to its TASKS.md § Discovered. Run before /plan-tasks when task ideas have accumulated from direct work sessions in the target repo.
disable-model-invocation: true
---

A target repo is attached to this session via --add-dir. When nightlight is discovering tasks on itself (self-targeting), --add-dir still resolves to a real path, but that path is the same as this session's own primary working directory. This skill has two independent sourcing phases: memory-mining (always runs) and repo-scanning (only when invoked with `--scan`).

Announce each phase to me in one line before starting it.

## Phase 1: locate memory

1. Announce: "Scanning `<repo>`'s memory for task candidates."
2. If the --add-dir path is the same as this session's own primary working directory (self-targeting — nightlight discovering tasks on itself): the target repo's own memory is simply this session's own memory, already loaded in context. Use its MEMORY.md directly and skip step 3 below.
3. Otherwise: list `~/.claude/projects/` and find the entry whose name matches the target repo's absolute path with `:` and path separators replaced by `-`. That is the target repo's *own* memory folder — distinct from nightlight's, since memory is scoped to whatever directory was the session's primary working directory when it was written, not to add-dir targets. Confirm the match against the real listing rather than assuming the encoding.
4. If no matching folder exists, or it has no MEMORY.md, say so plainly and skip to Phase 2 step 3 (repo-scan) or exit if `--scan` wasn't passed either.

## Phase 2: propose candidates

1. Read the target repo's MEMORY.md and the memory files it indexes. Judge which entries read as concrete, actionable tasks — most `project`-type memories are context, not tasks; only pull ones describing discrete work to do.
2. Cross-reference candidates against the target repo's current TASKS.md (open items) and `docs/tasks-archive/*.md` (completed items). Drop anything already covered.
3. If `--scan` was passed: dispatch the `task-scout` agent (foreground) against the target repo for additional candidates from codebase analysis. **`task-scout` is not built yet** — if it doesn't exist, tell me clearly and skip this part rather than failing the whole run.
4. Announce: "Found N candidate(s) from memory[, M from repo scan]." Present the full list — task text, one-line rationale, source (memory file name or scan finding) — for my approval. Do not write anything until I approve; let me accept or reject candidates individually.

## Phase 3: write approved candidates

1. Announce: "Writing N approved item(s) to TASKS.md."
2. Append each approved candidate as a new unchecked item under TASKS.md's `## Discovered` section (create the section if it's absent): one-line description plus source. Do not assign `#<n>` numbers or `[stack]` tags — that happens later, in `/plan-tasks`.
3. For memory-sourced items only: delete the source memory file and remove its line from that repo's MEMORY.md index. Leave rejected candidates untouched in memory.
4. Announce completion: "Done — N item(s) added to TASKS.md § Discovered, N memory file(s) cleared."

Do not implement any code in this session. Do not touch `docs/tasks-archive/` or `docs/nightlight-meta.json`.
