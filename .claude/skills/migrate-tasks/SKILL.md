---
name: migrate-tasks
description: Moves a target repo's open TASKS.md items into GitHub issues (local to GitHub only), reviews its unlabeled existing issues for staleness, then flips taskSource to github. Every create, close, and relabel needs per-item approval.
disable-model-invocation: true
---

A target repo is attached via --add-dir; args are `--to github` (the only supported direction). Linear and GitHub-to-local are out of scope. Nothing is created, closed, edited, or relabeled without my explicit per-item approval. Announce each phase in one line before starting it.

## Setup

1. Read the repo's `docs/nightlight-meta.json`. `taskSource` already `github`: stop and say so. Missing TASKS.md or no open items (`- [ ]`, `- [!]`, `- [/]`): skip phases 1-2 and go to phase 3.
2. Resolve the issue repo: `github.repo` from the meta file, else origin (`gh repo view --json nameWithOwner`). Load the module from the nightlight checkout: `source lib/task-source.sh`, then set `TS_GITHUB_REPO` and use `ts_find_related` and `ts_gh_label` from `lib/task-source-github.sh` (source it directly; the meta file is not yet `github`). Label names come from `ts_gh_label` (defaults `nl:agent-ready`, `nl:verify`, `nl:research`, `nl:blocked`, `nl:needs-human`, `nl:stack:<name>`), honoring any `labels` overrides.
3. Check the target repo is on its default branch with a clean tree before anything else; if not, stop and tell me.

## Phase 1: dedupe

1. List open TASKS.md items (all sections except Decisions and Discovered, which are never migrated; mention them as left behind). Each has `#<n>`, section, stack, text, glyph.
2. Per item run `ts_find_related <repo> "<short distinctive phrase>"` (open and closed issues). Also search for `Migrated from TASKS.md #<n>` so a prior migration run matches (idempotency). For matches that look implemented, dispatch `task-scout` in verify mode (item text, related issues with state, repo path).
3. Show each item with its matches (number, state, one-line reason) and ask per match: skip (already tracked), link (create, referencing the match), or create anyway. Items with no matches proceed. An item I skip is recorded as explicitly skipped.

## Phase 2: create issues

1. Present the full list of issues to create: title, labels, body. Write nothing until I approve; accept or reject individually.
2. Labels: section label (`nl:agent-ready`, `nl:verify`, `nl:research`), `nl:stack:<name>` when the item has a stack (not `solo`-less items: `solo` stays `nl:stack:solo`), `[!]` adds `nl:blocked`, `[/]` adds `nl:needs-human`. Missing labels: `gh label create` them (I approved the list above).
3. Body: the task text and acceptance criteria verbatim, a blank line, then `Migrated from TASKS.md #<n> (issue numbers differ from task numbers).` plus any `[!]`/`[/]` annotation, and links for "link" matches.
4. `gh issue create --repo <repo> --title ... --body ... --label ...` per approved item. Record `#<n>` to issue number. Failures: report and stop; nothing flips later.

## Phase 3: review existing unlabeled issues

1. `gh issue list --repo <repo> --state open --json number,title,labels,body,updatedAt`, keep issues with no `nl:*` label (exclude those just created).
2. Per issue, dispatch `task-scout` in verify mode (foreground, batched in one message, ~8 at a time) with the issue text and repo path, plus `git log` since the issue's `updatedAt` for recent merges.
3. Propose per issue: label into a section (and stack), close as stale (with the comment text shown), or leave. Apply only what I approve per item: `gh issue edit --add-label`, or `gh issue comment` then `gh issue close --reason "not planned"`. Never delete.

## Phase 4: flip the source

Only after every open TASKS.md item is an issue or was explicitly skipped by me, and phases 2-3 completed without error:

1. Confirm I want to flip and PR. Don't proceed without an explicit yes.
2. Resolve the default branch (`git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD`, fall back to `main` then `master`); not on it: stop, leave edits uncommitted, tell me.
3. Pull, branch off as `chore/tasks-migrate-<YYYY-MM-DD>` (append `-2`, `-3`... if taken).
4. Move, never delete: write a NEW `docs/tasks-archive/<YYYY-MM-DD>-migrated.md` holding every open TASKS.md item verbatim with its issue number or "skipped by human", then remove those items from TASKS.md (leave Decisions and Discovered content in place).
5. Set `"taskSource": "github"` in `docs/nightlight-meta.json` (create the file with `nextTaskNumber: 1, tasksCompleted: 0, tasksBlocked: 0` if missing, keep existing counters), plus `"github": {"repo": "<owner/name>"}` only if the backlog lives somewhere other than origin.
6. Stage only those files. Commit `chore(tasks): migrate TASKS.md to GitHub issues`, push, `gh pr create` to the default branch, report the URL.
7. Merge with `gh pr merge <branch-name> --squash --delete-branch` (exact branch name, matching the scoped permission), safe because everything in it was approved above. Failure: report and leave the PR open. On success check out the default branch and pull.

Do not implement any code in this session.
