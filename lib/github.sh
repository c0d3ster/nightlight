#!/usr/bin/env bash
# GitHub REST helpers. Every GitHub call nightlight makes is `gh api` REST:
# `gh issue`, `gh pr`, `gh label` and `gh repo` use GraphQL, which Claude Code
# cloud sessions block. Callers read REST's own response shape (state "open" or
# "closed", merged_at, labels[].name, head.ref).
#
# Source it for the gh_* functions. Run as a command it does one thing:
#   bash lib/github.sh slug <repo-path>    prints owner/name from origin

# gh_slug <repo-path>: owner/name from the checkout's origin URL (https, ssh,
# scp-style, or a proxy URL ending in /<owner>/<repo>). No API call.
gh_slug() {
  local url slug
  url="$(git -C "${1:-.}" remote get-url origin 2>&1)" || { echo "error: no origin remote in ${1:-.}: $url" >&2; return 1; }
  slug="$(sed -E 's#\.git/?$##; s#/+$##; s#^[^@/]+@([^:/]+):#\1/#' <<< "$url" | awk -F/ 'NF >= 2 {print $(NF-1) "/" $NF}')"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "error: can't read owner/repo from origin URL $url" >&2; return 1; }
  printf '%s\n' "$slug"
}

# gh_uri <text>: percent-encodes one query-string value.
gh_uri() { jq -rn --arg s "$1" '$s | @uri'; }

# gh_paged <endpoint> [jq-filter]: every element of every page of a list
# endpoint, through the filter (default .; it must yield objects, since gh
# prints strings raw), as one JSON array. Fails when gh does (a pipe into jq -s
# would hide that).
gh_paged() {
  local out
  out="$(gh api --paginate "$1" --jq ".[] | ${2:-.}")" || return 1
  jq -s . <<< "$out"
}

# gh_issues <repo> <open|closed|all> [label]: issues, pull requests dropped.
gh_issues() {
  local q="state=$2&per_page=100"
  [[ -n "${3:-}" ]] && q="$q&labels=$(gh_uri "$3")"
  gh_paged "repos/$1/issues?$q" 'select(.pull_request | not)'
}

# gh_branch_pr <repo> <branch>: the PR gh's own branch lookup would show, the
# branch's open PR, else its newest, or null when it has none. Only PRs from
# <repo>'s own branches (REST filters head on <owner>:<branch>). Fails when gh
# does, so callers can tell "no PR" from "couldn't ask".
gh_branch_pr() {
  local prs
  prs="$(gh_paged "repos/$1/pulls?state=all&head=$(gh_uri "${1%%/*}:$2")&per_page=100")" || return 1
  jq -c '(map(select(.state == "open")) | first) // (sort_by(.number) | last)' <<< "$prs"
}

# gh_write <gh api args>...: runs a write; DRY_RUN=1 prints the exact command on
# stderr instead.
gh_write() {
  if [[ "${DRY_RUN:-}" == 1 ]]; then
    { printf 'DRY_RUN: gh api'; printf ' %q' "$@"; echo; } >&2
    return 0
  fi
  gh api "$@"
}

# gh_delete_branch <repo-path> <branch>: deletes the branch on origin,
# best-effort. Cloud sessions refuse it, so a failure prints a warning naming
# the branch and returns 1; callers report it and carry on.
gh_delete_branch() {
  local path="$1" branch="$2" err
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "error: unsafe branch name '$branch'" >&2; return 2; }
  if [[ "${DRY_RUN:-}" == 1 ]]; then
    echo "DRY_RUN: git -C $path push --quiet origin --delete $branch" >&2
    return 0
  fi
  err="$(git -C "$path" push --quiet origin --delete "$branch" 2>&1)" && return 0
  echo "warning: couldn't delete branch $branch on origin (delete it from GitHub or a local checkout): ${err//$'\n'/ }" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == slug && -n "${2:-}" ]] || { echo "usage: bash lib/github.sh slug <repo-path>" >&2; exit 2; }
  gh_slug "$2"
fi
