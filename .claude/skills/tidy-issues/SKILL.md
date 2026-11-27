---
name: tidy-issues
description: Reviews a repo's open, unlabeled GitHub issues against its code and merged PRs, then links and closes the ones that shipped or went stale, and (only when labels are on) labels the rest into nl:* sections. Works whatever the repo's task source. Every comment, close, and label needs per-item approval.
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Bash|Read|mcp__.*"
      hooks:
        - type: command
          command: 'f="$(cd -P "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && cd ../../.. && pwd)/lib/guard.sh"; [ -f "$f" ] || { echo "nightlight guard not found from $CLAUDE_PLUGIN_ROOT; re-run install.sh" >&2; exit 2; }; exec bash "$f"'
---

## Target repo

`<nl>` below is the nightlight checkout holding this skill, as an absolute path: the skill's base directory with symlinks followed (it may be loaded through a link in `~/.claude/skills`), three levels up: `cd -P <skill base directory> && cd ../../.. && pwd`. The target repo is, in order: the --add-dir repo if one is attached; else the repo the args name (a sibling checkout's name, or a path); else the current working directory's repo (`git rev-parse --show-toplevel`) when it is a git checkout other than `<nl>`; else list the git checkouts beside `<nl>` and ask me to pick. Resolve it to an absolute path. Run scripts from `<nl>` by absolute path, never relative to the cwd. GitHub calls are REST: copy the `gh api` commands below as written, and never use `gh issue`, `gh pr`, `gh label` or `gh repo`, which need GraphQL and fail in cloud sessions. `<owner/repo>` is `github.repo` from the repo's `docs/nightlight-meta.json` for issues when set, else `bash <nl>/lib/github.sh slug <repo-path>` (PRs always use the latter).

Args are `--labels` or `--no-labels`, plus the target repo when none is attached (`tidy.sh` sets one from the repo's `taskSource`; none given means `--no-labels`). Nothing is commented on, closed, edited, or relabeled without my explicit per-item approval. Never delete an issue. This session writes nothing to the repo's files and opens no PR. Announce each step in one line before starting it.

`--labels` is only for repos on the GitHub task source (or being migrated to it). For a repo already on issues but not yet opted in, `pnpm tidy <repo> --labels` is the labeling step, then `pnpm migrate <repo> --to github` flips `taskSource`. This skill never changes `taskSource`. With `--no-labels`, never add or create `nl:*` labels, and never offer "label" as an action: the labels would mean nothing to a repo that dispatches from `TASKS.md`.

## Steps

1. Resolve the issue repo: `github.repo` from the repo's `docs/nightlight-meta.json` if set, else origin (`bash <nl>/lib/github.sh slug <repo-path>`). With `--labels`, load label names: `source <nl>/lib/task-source.sh && source <nl>/lib/task-source-github.sh`, set `TS_GITHUB_REPO`, and use `ts_gh_label` (source the module directly; the meta file may not be `github` yet), honoring any `labels` overrides. Before applying labels, run `bash <nl>/lib/ensure-labels.sh <repo-path>` (creates any missing `nl:*` labels).
2. `gh api --paginate 'repos/<owner/repo>/issues?state=open&per_page=100' --jq '.[] | select(.pull_request | not) | {number, title, labels: [.labels[].name], updated_at, body}'`. Keep issues with no `nl:*` label, and exclude any issue the calling session just created.
3. Checkpoint before any scouting: show the count and each issue's number and title, then ask whether to review them: all, only the numbers I name, or skip. No answer means skip. Skip ends the session with nothing dispatched or changed.
4. Fetch merged PRs once (`gh api --paginate 'repos/<owner/repo>/pulls?state=closed&per_page=100' --jq '.[] | select(.merged_at) | {number, title, head: .head.ref, merged_at, body}'`) so each issue is matched without a GitHub call per issue.
5. Per chosen issue, dispatch `task-scout` in verify mode (foreground, batched in one message, ~8 at a time) with the issue text, any merged PRs that reference the issue number or share distinctive title words, the repo path, and `git log` since the issue's `updated_at`. It reports implemented, partial, or not implemented with evidence.
6. Propose one action per issue and show the comment text that would be posted:
   - **Shipped** (scout says implemented, ideally with a merged PR): comment linking the PR number(s) and the evidence, then close as completed.
   - **Stale** (obsolete, superseded, or no longer applies, with the reason): comment with the reason, then close as not planned.
   - **Label** (`--labels` only, still wanted and not shipped): add its section label (and `nl:stack:<name>` if I name one).
   - **Leave**, the default when unsure.
7. Apply only what I approve, per item: comment with `gh api -X POST repos/<owner/repo>/issues/<n>/comments -F body=@<file> --jq .html_url`, then close with `gh api -X PATCH repos/<owner/repo>/issues/<n> -f state=closed -f state_reason=completed` (shipped) or `-f state_reason=not_planned` (stale); or label with `gh api -X POST repos/<owner/repo>/issues/<n>/labels -f 'labels[]=<section>' [-f 'labels[]=nl:stack:<name>']` (adds, keeps existing labels). Report a one-line summary at the end: closed as completed, closed as not planned, labeled, left.

Do not implement any code in this session.
