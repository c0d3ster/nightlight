#!/usr/bin/env bash
# usage: pnpm discover [repo] [--scan]
#   with repo: mine that one repo's memory (and, with --scan, its codebase)
#              for task candidates and propose additions to its TASKS.md
#   without:   same, but for every repo under PROJECT_REPOS_DIR -- discover
#              has no TASKS.md prerequisite (it can create one), so every
#              repo qualifies, no filtering needed
set -e

NL_CALLER_PWD="${NL_CALLER_PWD:-$PWD}"
cd "$(dirname "$0")"
source lib/paths.sh
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"

REPO=""
SCAN_FLAG=""
for arg in "$@"; do
  if [[ "$arg" == "--scan" ]]; then
    SCAN_FLAG=" --scan"
  else
    REPO="$arg"
  fi
done

if [[ -n "$REPO" ]]; then
  REPO="$(nl_resolve_repo "$REPO")" || exit 1
  MSYS_NO_PATHCONV=1 claude "/discover-tasks$SCAN_FLAG" --add-dir "$REPO"
else
  # No repo given and no filter exists for discover, so every repo under
  # PROJECT_REPOS_DIR is in scope -- attach the whole folder as one --add-dir
  # rather than building one flag per repo (identical access either way when
  # nothing gets excluded). The /discover-tasks skill enumerates the repo
  # subdirectories itself once it's running.
  PROJECT_REPOS_DIR="$(nl_abspath "$PROJECT_REPOS_DIR")"
  MSYS_NO_PATHCONV=1 claude "/discover-tasks$SCAN_FLAG" --add-dir "$PROJECT_REPOS_DIR"
fi
