#!/usr/bin/env bash
# usage: pnpm plan [repo] — opens an interactive planning session
#   with repo: plans that one repo
#   without:   plans every repo under PROJECT_REPOS_DIR with open work in its
#              configured task source (same gate overnight.sh's run_repo uses)
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
source lib/task-source.sh

REPO="$1"

if [[ -n "$REPO" ]]; then
  # the repo's own folder name (e.g. "nightlight") means this checkout, wherever
  # it lives; the script cd'd to its own dir above, so "." is this repo.
  [[ "$REPO" != "$(basename "$PWD")" ]] || REPO="."
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
    load_task_source "$d" || { echo "skip: $name (task source unavailable)"; continue; }
    [[ "$TASK_SOURCE" != local || -f "$d/TASKS.md" ]] || { echo "skip: $name (no TASKS.md)"; continue; }
    ts_is_eligible "$d" || { echo "skip: $name (no open tasks)"; continue; }
    ADD_DIRS+=(--add-dir "$(cd "$d" && pwd -W)")
  done
  [[ ${#ADD_DIRS[@]} -gt 0 ]] || { echo "no repos under PROJECT_REPOS_DIR have open tasks"; exit 0; }
  MSYS_NO_PATHCONV=1 claude "/plan-tasks" "${ADD_DIRS[@]}"
fi
