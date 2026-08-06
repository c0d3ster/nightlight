#!/bin/bash
# usage: pnpm discover [repo] [--scan]
#   with repo: mine that one repo's memory (and, with --scan, its codebase)
#              for task candidates and propose additions to its TASKS.md
#   without:   same, but for every repo under PROJECT_REPOS_DIR -- discover
#              has no TASKS.md prerequisite (it can create one), so every
#              repo qualifies, no filtering needed
set -e

cd "$(dirname "$0")"
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
  [[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
  # resolve to an absolute path so "." and "./" (e.g. self-targeting nightlight
  # from inside its own directory) end up byte-identical before reaching --add-dir.
  # pwd -W (not plain pwd) keeps the Windows-style uppercase drive letter --
  # plain pwd's POSIX-style lowercase-drive path (/c/Users/...) doesn't match
  # the casing Claude Code's directory-trust store uses elsewhere, so trust
  # never "sticks" and every subrepo re-prompts on every run.
  REPO="$(cd "$REPO" && pwd -W)"
  MSYS_NO_PATHCONV=1 claude "/discover-tasks$SCAN_FLAG" --add-dir "$REPO"
else
  # No repo given and no filter exists for discover, so every repo under
  # PROJECT_REPOS_DIR is in scope -- attach the whole folder as one --add-dir
  # rather than building one flag per repo (identical access either way when
  # nothing gets excluded). The /discover-tasks skill enumerates the repo
  # subdirectories itself once it's running.
  PROJECT_REPOS_DIR="$(cd "$PROJECT_REPOS_DIR" && pwd -W)"
  MSYS_NO_PATHCONV=1 claude "/discover-tasks$SCAN_FLAG" --add-dir "$PROJECT_REPOS_DIR"
fi
