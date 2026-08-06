#!/bin/bash
# usage: pnpm plan [repo] — opens an interactive planning session
#   with repo: plans that one repo
#   without:   plans every repo under PROJECT_REPOS_DIR that has open,
#              unchecked TASKS.md work (same gate overnight.sh's run_repo uses)
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"

REPO="$1"

if [[ -n "$REPO" ]]; then
  [[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
  # resolve to an absolute path so "." and "./" (e.g. self-targeting nightlight
  # from inside its own directory) end up byte-identical before reaching --add-dir.
  # pwd -W (not plain pwd) keeps the Windows-style uppercase drive letter --
  # plain pwd's POSIX-style lowercase-drive path (/c/Users/...) doesn't match
  # the casing Claude Code's directory-trust store uses elsewhere, so trust
  # never "sticks" and every subrepo re-prompts on every run.
  REPO="$(cd "$REPO" && pwd -W)"
  MSYS_NO_PATHCONV=1 claude "/plan-tasks" --add-dir "$REPO"
else
  # No repo given: only attach repos that actually have unplanned work -- a
  # TASKS.md with at least one unchecked item -- same gate overnight.sh's
  # run_repo uses. Computed here in plain bash, before claude ever launches,
  # so repos without qualifying work are never attached at all.
  ADD_DIRS=()
  for d in "$PROJECT_REPOS_DIR"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    tasks="$d/TASKS.md"
    [[ -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; continue; }
    grep -Eq '^\s*- \[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; continue; }
    ADD_DIRS+=(--add-dir "$(cd "$d" && pwd -W)")
  done
  [[ ${#ADD_DIRS[@]} -gt 0 ]] || { echo "no repos under PROJECT_REPOS_DIR have open tasks"; exit 0; }
  MSYS_NO_PATHCONV=1 claude "/plan-tasks" "${ADD_DIRS[@]}"
fi
