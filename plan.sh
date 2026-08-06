#!/bin/bash
# usage: pnpm plan <repo> — opens an interactive planning session on the target repo
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"

REPO="${1:?usage: plan.sh <repo>}"
[[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
# resolve to an absolute path so "." and "./" (e.g. self-targeting nightlight
# from inside its own directory) end up byte-identical before reaching --add-dir.
# pwd -W (not plain pwd) keeps the Windows-style uppercase drive letter --
# plain pwd's POSIX-style lowercase-drive path (/c/Users/...) doesn't match
# the casing Claude Code's directory-trust store uses elsewhere, so trust
# never "sticks" and every subrepo re-prompts on every run.
REPO="$(cd "$REPO" && pwd -W)"

MSYS_NO_PATHCONV=1 claude  "/plan-tasks" --add-dir "$REPO"