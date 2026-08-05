#!/bin/bash
# usage: pnpm discover <repo> [--scan] — mines the target repo's own memory (and,
# with --scan, its codebase) for task candidates and proposes additions to its TASKS.md
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"

REPO="${1:?usage: discover.sh <repo> [--scan]}"
[[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
# resolve to an absolute path so "." and "./" (e.g. self-targeting nightlight
# from inside its own directory) end up byte-identical before reaching --add-dir
REPO="$(cd "$REPO" && pwd)"

SCAN_FLAG=""
[[ "$2" == "--scan" ]] && SCAN_FLAG=" --scan"

MSYS_NO_PATHCONV=1 claude "/discover-tasks$SCAN_FLAG" --add-dir "$REPO"
