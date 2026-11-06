#!/usr/bin/env bash
# usage: pnpm tidy <repo> [--labels | --no-labels] — opens an interactive,
#   approval-gated session that reviews one repo's open, unlabeled GitHub issues
#   against its code and merged PRs, then links and closes the ones that shipped
#   or went stale. Works on any repo, whatever its task source. A repo argument
#   is required (no no-arg fan-out).
#   Labeling issues into nl:* sections only makes sense when the repo's
#   docs/nightlight-meta.json has taskSource "github", so that is the default;
#   --labels / --no-labels override it.
#   Adopting a repo that already has issues but no TASKS.md: run
#   `pnpm tidy <repo> --labels` (per-item approval), then `pnpm migrate <repo> --to github`
#   to flip taskSource. Tidy never writes taskSource. GitHub only; Linear is out of scope.
set -e

cd "$(dirname "$0")"
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
command -v gh >/dev/null || { echo "gh is required for tidy"; exit 1; }

REPO=""
LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --labels) LABELS="--labels"; shift ;;
    --no-labels) LABELS="--no-labels"; shift ;;
    *) REPO="$1"; shift ;;
  esac
done

[[ -n "$REPO" ]] || { echo "usage: pnpm tidy <repo> [--labels | --no-labels]"; exit 1; }

# same repo resolution as plan.sh / discover.sh / migrate.sh
[[ "$REPO" != "$(basename "$PWD")" ]] || REPO="."
[[ -d "$REPO" ]] || REPO="$PROJECT_REPOS_DIR/$REPO"
REPO="$(cd "$REPO" && pwd -W)"

# default: label only when the repo's task source is github
if [[ -z "$LABELS" ]]; then
  source_name="$(jq -r '.taskSource // "local"' "$REPO/docs/nightlight-meta.json" 2>/dev/null || echo local)"
  [[ "$source_name" == "github" ]] && LABELS="--labels" || LABELS="--no-labels"
fi

MSYS_NO_PATHCONV=1 claude "/tidy-issues $LABELS" --add-dir "$REPO"
