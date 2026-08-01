#!/bin/bash
# usage: pnpm overnight [repo]
#   with repo: run that one repo
#   without:   run every repo under PROJECT_REPOS_DIR that has open TASKS.md work
set -e
cd "$(dirname "$0")"

# Always run with the latest rules
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"

PROMPT='A target repo has been added to this session via --add-dir. Read TASKS.md in that target repo and run an overnight session per the "Overnight Agent Workflow" rules in CLAUDE.md. Work through ALL Agent-Ready, Verify, and Research items in order. Do not stop until every item in those sections is either complete, annotated NEEDS HUMAN, or annotated blocked. Then do the end-of-session housekeeping. Only after all of that is the session over.'

run_repo() {
  local repo_path="$1"
  local name; name="$(basename "$repo_path")"
  local tasks="$repo_path/TASKS.md"

  [[ -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; return 0; }
  grep -Eq '^\s*- \[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; return 0; }

  echo "=== $name ==="
  git -C "$repo_path" checkout main && git -C "$repo_path" pull

  mkdir -p logs
  claude -p "$PROMPT" \
    --model sonnet \
    --permission-mode acceptEdits \
    --settings .claude/settings.json \
    --add-dir "$repo_path" \
    2>&1 | tee "logs/$name-$(date +%F).log"
}

if [[ -n "$1" ]]; then
  TARGET="$1"
  [[ -d "$TARGET" ]] || TARGET="$PROJECT_REPOS_DIR/$TARGET"
  run_repo "$TARGET"
else
  for d in "$PROJECT_REPOS_DIR"/*/; do
    run_repo "${d%/}"
  done
fi