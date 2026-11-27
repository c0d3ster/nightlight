#!/usr/bin/env bash
# usage: bash lib/merge-pr.sh <repo-path> <branch>
#
# Rebase-merges the open PR for <branch> on the checkout's origin repo, then
# deletes the branch on origin, best-effort (a refused delete warns and still
# exits 0: the merge itself succeeded). Only chore/tasks-(discover|plan|migrate)-*
# branches: the skills merge their own approved task-list PRs through this
# script, so the permission allowlist can scope merges by branch, which a raw
# `gh api -X PUT .../merge` (by PR number) can't. DRY_RUN=1 prints the writes.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github.sh"

repo="${1:?usage: merge-pr.sh <repo-path> <branch>}"
branch="${2:?usage: merge-pr.sh <repo-path> <branch>}"
[[ "$branch" =~ ^chore/tasks-(discover|plan|migrate)-[A-Za-z0-9._-]+$ ]] \
  || { echo "error: refusing to merge $branch: only chore/tasks-discover-*, -plan-* and -migrate-* branches" >&2; exit 2; }
slug="$(gh_slug "$repo")" || exit 1

num="$(gh api "repos/$slug/pulls?state=open&head=$(gh_uri "${slug%%/*}:$branch")" --jq '.[0].number // empty')" || exit 1
[[ -n "$num" ]] || { echo "error: no open pull request for branch $branch in $slug" >&2; exit 1; }
gh_write -X PUT "repos/$slug/pulls/$num/merge" -f merge_method=rebase >/dev/null || exit 1
echo "merged #$num ($branch) with rebase"
gh_delete_branch "$repo" "$branch" || true
