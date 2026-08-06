#!/bin/bash
# usage: pnpm nightlight [repo] [--scan] [overnight flags]
#   with repo: chains discover -> plan -> overnight for that one repo
#   without:   chains discover -> plan -> overnight, each in its own
#              no-arg multi-repo mode across PROJECT_REPOS_DIR
#
#   --scan is forwarded to discover only.
#   --stop-after/--limit/--stack/--extra-instructions/--override-prompt are
#   forwarded to overnight only, exactly as overnight.sh itself defines them
#   (including its own single-repo requirement for all but --limit) -- see
#   overnight.sh's own usage comment for what each does.
set -e
cd "$(dirname "$0")"

REPO=""
SCAN_FLAG=""
OVERNIGHT_FLAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) SCAN_FLAG="--scan"; shift ;;
    --stop-after|--limit|--stack|--extra-instructions|--override-prompt)
      OVERNIGHT_FLAGS+=("$1" "$2"); shift 2 ;;
    --*) echo "unknown flag: $1"; exit 1 ;;
    *) REPO="$1"; shift ;;
  esac
done

REPO_ARGS=(); [[ -n "$REPO" ]] && REPO_ARGS+=("$REPO")
DISCOVER_ARGS=("${REPO_ARGS[@]}"); [[ -n "$SCAN_FLAG" ]] && DISCOVER_ARGS+=("--scan")

echo "=== discover ==="
./discover.sh "${DISCOVER_ARGS[@]}"

echo
echo "=== plan ==="
./plan.sh "${REPO_ARGS[@]}"

echo
read -p "Discover and plan are done. Start the overnight run now? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Skipping the overnight run -- run ./overnight.sh${REPO:+ $REPO} whenever you're ready."
  exit 0
fi

echo "=== overnight ==="
./overnight.sh "${REPO_ARGS[@]}" "${OVERNIGHT_FLAGS[@]}"
