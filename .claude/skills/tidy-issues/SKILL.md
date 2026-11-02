---
name: tidy-issues
description: Reviews a repo's open, unlabeled GitHub issues against its code and merged PRs, then links and closes the ones that shipped or went stale, and (only when labels are on) labels the rest into nl:* sections. Works whatever the repo's task source. Every comment, close, and label needs per-item approval.
disable-model-invocation: true
---

A target repo is attached via --add-dir; args are `--labels` or `--no-labels` (`tidy.sh` sets one from the repo's `taskSource`; none given means `--no-labels`). Nothing is commented on, closed, edited, or relabeled without my explicit per-item approval. Never delete an issue. This session writes nothing to the repo's files and opens no PR. Announce each step in one line before starting it.

`--labels` is only for repos on the GitHub task source (or being migrated to it). With `--no-labels`, never add or create `nl:*` labels, and never offer "label" as an action: the labels would mean nothing to a repo that dispatches from `TASKS.md`.

## Steps

1. Resolve the issue repo: `github.repo` from the repo's `docs/nightlight-meta.json` if set, else origin (`gh repo view --json nameWithOwner`). With `--labels`, load label names from the nightlight checkout: `source lib/task-source.sh`, set `TS_GITHUB_REPO`, and use `ts_gh_label` from `lib/task-source-github.sh` (source it directly; the meta file may not be `github` yet), honoring any `labels` overrides. Missing `nl:*` labels you are about to apply: `gh label create` them first.
2. `gh issue list --repo <repo> --state open --json number,title,labels,body,updatedAt`. Keep issues with no `nl:*` label, and exclude any issue the calling session just created.
3. Gate before any scouting: show the count and each issue's number and title, then ask whether to review them: all, only the numbers I name, or skip. No answer means skip. Skip ends the session with nothing dispatched or changed.
4. Fetch merged PRs once (`gh pr list --repo <repo> --state merged --limit 300 --json number,title,headRefName,mergedAt,body`) so each issue is matched without a `gh` call per issue.
5. Per chosen issue, dispatch `task-scout` in verify mode (foreground, batched in one message, ~8 at a time) with the issue text, any merged PRs that reference the issue number or share distinctive title words, the repo path, and `git log` since the issue's `updatedAt`. It reports implemented, partial, or not implemented with evidence.
6. Propose one action per issue and show the comment text that would be posted:
   - **Shipped** (scout says implemented, ideally with a merged PR): comment linking the PR number(s) and the evidence, then close as completed.
   - **Stale** (obsolete, superseded, or no longer applies, with the reason): comment with the reason, then close as not planned.
   - **Label** (`--labels` only, still wanted and not shipped): add its section label (and `nl:stack:<name>` if I name one).
   - **Leave**, the default when unsure.
7. Apply only what I approve, per item: `gh issue comment` then `gh issue close --reason completed` (shipped) or `gh issue close --reason "not planned"` (stale), or `gh issue edit --add-label` (label). Report a one-line summary at the end: closed as completed, closed as not planned, labeled, left.

Do not implement any code in this session.
