#!/usr/bin/env bash
# usage: bash lib/stack-notes.sh <repo-path> [--keep <stack>]... [--remote <notes-dir>]
#
# Local mode (default): notes are docs/stack-notes/<stack>.md files in the repo.
# Remote mode (--remote <dir>, GitHub and Linear): the runner exported each
# stack's tracker notes to <dir>/<stack>.md first (ts_stack_notes_export). Same
# branch deletion, but a finished stack is only reported ("finished <stack>",
# the caller retitles its tracker notes "[done]"); nothing in the repo changes.
# The one exception is a legacy docs/stack-notes/<stack>.md file left from
# before notes moved to the tracker: it is the branch source when the tracker has
# no notes for that stack, and when that stack is finished it is `git rm`ed
# (staged, printed as "removed-legacy"). That is the only commit remote
# housekeeping can still make.
#
# The one stack-notes sweep, shared by housekeeping (all three task sources) and
# /migrate-tasks. For every docs/stack-notes/<stack>.md in the target repo:
#   1. check each "Branch: " line's PR (gh pr view); delete any branch whose PR
#      MERGED, locally and on origin (even when the file is kept)
#   2. `git rm` the file when the stack is finished (staged, never committed;
#      the caller's commit includes it)
# A stack is finished only when every Branch: PR is MERGED, it is not named by
# --keep, and (local source) no open TASKS.md task carries [stack: <name>].
# The caller passes one --keep per stack that still has open work elsewhere:
# a stack dispatched this run, or one with open tracker issues (nl:stack:<name>).
# Any gh failure, an unmerged PR, or zero Branch: lines keeps the file.
# Prints one line per decision: "deleted-branch", "removed", "finished",
# "removed-legacy" or "kept <reason>".

set -u

repo="${1:?usage: stack-notes.sh <repo-path> [--keep <stack>]...}"
shift
keep=" "
remote_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) keep="$keep${2:?--keep needs a stack name} "; shift 2 ;;
    --remote) remote_dir="${2:?--remote needs a notes dir}"; shift 2 ;;
    *) echo "error: unknown argument $1"; exit 2 ;;
  esac
done

notes_dir="$repo/docs/stack-notes"
[[ -d "$notes_dir" || -n "$remote_dir" ]] || { echo "no docs/stack-notes in $repo, nothing to sweep"; exit 0; }

# Stacks with an open task in a local TASKS.md, under any unchecked glyph.
if [[ -z "$remote_dir" && -f "$repo/TASKS.md" ]]; then
  while IFS= read -r name; do
    keep="$keep$name "
  done < <(sed -nE 's/^- \[[ !/]\] .*\[stack: ([^]]+)\].*/\1/p' "$repo/TASKS.md")
fi

# Stack names to sweep: every notes file, tracker export first, then legacy.
stacks=""
for file in "$notes_dir"/*.md ${remote_dir:+"$remote_dir"/*.md}; do
  [[ -e "$file" ]] && stacks="$stacks$(basename "$file" .md) "
done
stacks="$(printf '%s' "$stacks" | tr ' ' '
' | sort -u)"

while IFS= read -r stack; do
  [[ -n "$stack" ]] || continue
  file="$notes_dir/$stack.md"
  [[ -n "$remote_dir" && -e "$remote_dir/$stack.md" ]] && file="$remote_dir/$stack.md"
  branches="$(sed -n 's/^Branch: //p' "$file")"
  if [[ -z "$branches" ]]; then
    echo "kept $stack: no Branch: lines"
    continue
  fi

  all_merged=1
  while IFS= read -r branch; do
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "kept $stack: unsafe branch name '$branch'"; all_merged=0; continue; }
    if ! state="$(cd "$repo" && gh pr view "$branch" --json state --jq .state 2>/dev/null)"; then
      # A discarded retry attempt leaves an entry whose branch is gone and never
      # had a PR; it must not hold the stack open.
      if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"         && ! git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1         && [[ "$(cd "$repo" && gh pr list --head "$branch" --state all --json number --jq length 2>/dev/null)" == "0" ]]; then
        echo "ignored-stale $branch (no branch, no PR)"
        continue
      fi
      echo "kept $stack: gh could not read the PR for $branch"
      all_merged=0
      continue
    fi
    if [[ "$state" != "MERGED" ]]; then
      echo "kept $stack: $branch is $state"
      all_merged=0
      continue
    fi
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 && echo "deleted-branch $branch (local)"
    if git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      git -C "$repo" push --quiet origin --delete "$branch" 2>/dev/null && echo "deleted-branch $branch (origin)"
    fi
  done <<< "$branches"

  [[ "$all_merged" == 1 ]] || continue
  if [[ "$keep" == *" $stack "* ]]; then
    echo "kept $stack: still has open work"
    continue
  fi
  if [[ -n "$remote_dir" ]]; then
    echo "finished $stack"
    [[ -e "$notes_dir/$stack.md" ]] && git -C "$repo" rm --quiet "docs/stack-notes/$stack.md" && echo "removed-legacy $stack"
    continue
  fi
  git -C "$repo" rm --quiet "docs/stack-notes/$stack.md" && echo "removed $stack"
done <<< "$stacks"
