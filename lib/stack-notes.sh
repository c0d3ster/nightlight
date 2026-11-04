#!/usr/bin/env bash
# usage: bash lib/stack-notes.sh <repo-path> [--keep <stack>]...
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
# Prints one line per decision: "deleted-branch", "removed", or "kept <reason>".

set -u

repo="${1:?usage: stack-notes.sh <repo-path> [--keep <stack>]...}"
shift
keep=" "
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) keep="$keep${2:?--keep needs a stack name} "; shift 2 ;;
    *) echo "error: unknown argument $1"; exit 2 ;;
  esac
done

notes_dir="$repo/docs/stack-notes"
[[ -d "$notes_dir" ]] || { echo "no docs/stack-notes in $repo, nothing to sweep"; exit 0; }

# Stacks with an open task in a local TASKS.md, under any unchecked glyph.
if [[ -f "$repo/TASKS.md" ]]; then
  while IFS= read -r name; do
    keep="$keep$name "
  done < <(sed -nE 's/^- \[[ !/]\] .*\[stack: ([^]]+)\].*/\1/p' "$repo/TASKS.md")
fi

for file in "$notes_dir"/*.md; do
  [[ -e "$file" ]] || continue
  stack="$(basename "$file" .md)"
  branches="$(sed -n 's/^Branch: //p' "$file")"
  if [[ -z "$branches" ]]; then
    echo "kept $stack: no Branch: lines"
    continue
  fi

  all_merged=1
  while IFS= read -r branch; do
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "kept $stack: unsafe branch name '$branch'"; all_merged=0; continue; }
    if ! state="$(cd "$repo" && gh pr view "$branch" --json state --jq .state 2>/dev/null)"; then
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
  git -C "$repo" rm --quiet "docs/stack-notes/$stack.md" && echo "removed $stack"
done
