#!/usr/bin/env bash
# usage: pnpm plan [repo] — opens an interactive planning session
#   with repo: plans that one repo
#   without:   plans every repo under PROJECT_REPOS_DIR with open work in its
#              configured task source (same gate overnight.sh's run_repo uses)
set -e

NL_CALLER_PWD="${NL_CALLER_PWD:-$PWD}"
cd "$(dirname "$0")"
source lib/paths.sh
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
source lib/task-source.sh

REPO="$1"

if [[ -n "$REPO" ]]; then
  REPO="$(nl_resolve_repo "$REPO")" || exit 1
  MSYS_NO_PATHCONV=1 claude "/plan-tasks" --add-dir "$REPO"
else
  # No repo given: only attach repos that actually have unplanned work -- a
  # TASKS.md with at least one unchecked item -- same gate overnight.sh's
  # run_repo uses. Computed here in plain bash, before claude ever launches,
  # so repos without qualifying work are never attached at all.
  ADD_DIRS=()
  ERRORED=0
  for d in "$PROJECT_REPOS_DIR"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    load_task_source "$d" || { echo "skip: $name (task source unavailable)"; continue; }
    [[ "$TASK_SOURCE" != local || -f "$d/TASKS.md" ]] || { echo "skip: $name (no TASKS.md)"; continue; }
    rc=0; ts_is_eligible "$d" || rc=$?
    if [[ $rc -eq 1 ]]; then echo "skip: $name (no open tasks)"; continue; fi
    if [[ $rc -ne 0 ]]; then echo "skip: $name (task source error, see above)"; ERRORED=$((ERRORED+1)); continue; fi
    ADD_DIRS+=(--add-dir "$(nl_abspath "$d")")
  done
  if [[ ${#ADD_DIRS[@]} -eq 0 ]]; then
    [[ $ERRORED -eq 0 ]] || { echo "error: task source failed for $ERRORED repo(s); no repos could be checked"; exit 1; }
    echo "no repos under PROJECT_REPOS_DIR have open tasks"; exit 0
  fi
  MSYS_NO_PATHCONV=1 claude "/plan-tasks" "${ADD_DIRS[@]}"
fi
