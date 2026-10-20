#!/usr/bin/env bash
# usage: pnpm migrate <repo> --to github — opens an interactive, approval-gated
#   session that moves one repo's open TASKS.md items into GitHub issues.
#   Local-to-GitHub only; a repo argument is required (no no-arg fan-out,
#   since this rewrites a repo's task source).
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
command -v gh >/dev/null || { echo "gh is required for migrate"; exit 1; }

REPO=""
TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --to=*) TO="${1#--to=}"; shift ;;
    *) REPO="$1"; shift ;;
  esac
done

[[ -n "$REPO" ]] || { echo "usage: pnpm migrate <repo> --to github"; exit 1; }
[[ "$TO" == "github" ]] || { echo "only --to github is supported (local to GitHub, one direction)"; exit 1; }

# same repo resolution as plan.sh / discover.sh
[[ "$REPO" != "$(basename "$PWD")" ]] || REPO="."
[[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
REPO="$(cd "$REPO" && pwd -W)"

MSYS_NO_PATHCONV=1 claude "/migrate-tasks --to github" --add-dir "$REPO"
