#!/bin/bash
# usage: pnpm overnight [repo] [flags]
#   with repo: run that one repo
#   without:   run every repo under PROJECT_REPOS_DIR that has open TASKS.md work
#
# flags (compose with the base prompt, they don't replace it):
#   --stop-after N        only complete tasks numbered 1..N (continuous numbering
#                          down TASKS.md, see README), then stop.
#   --stack <name>        only work tasks annotated [stack: <name>], skip every
#                          other stack this run.
#   --extra-instructions "<text>"
#                          append arbitrary free-form instructions for this run.
#   --override-prompt "<text>"
#                          replace the base prompt entirely instead of appending
#                          to it. Loses the housekeeping/workflow framing unless
#                          <text> restates it - prefer the flags above.
set -e
cd "$(dirname "$0")"

# Always run with the latest rules
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }

REPO=""
STOP_AFTER=""
STACK=""
EXTRA_INSTRUCTIONS=""
OVERRIDE_PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --extra-instructions) EXTRA_INSTRUCTIONS="$2"; shift 2 ;;
    --override-prompt) OVERRIDE_PROMPT="$2"; shift 2 ;;
    --*) echo "unknown flag: $1"; exit 1 ;;
    *) REPO="$1"; shift ;;
  esac
done

BASE_PROMPT='A target repo has been added to this session via --add-dir. Read TASKS.md in that target repo and run an overnight session per the "Overnight Agent Workflow" rules in CLAUDE.md. Work through ALL Agent-Ready, Verify, and Research items in order. Do not stop until every item in those sections is either complete, annotated NEEDS HUMAN, or annotated blocked. Then do the end-of-session housekeeping. Only after all of that is the session over.'

if [[ -n "$OVERRIDE_PROMPT" ]]; then
  PROMPT="$OVERRIDE_PROMPT"
else
  PROMPT="$BASE_PROMPT"
  if [[ -n "$STOP_AFTER" ]]; then
    PROMPT="$PROMPT

IMPORTANT - special instructions for this run: only complete tasks numbered 1 through $STOP_AFTER in TASKS.md (continuous numbering down the file, across all sections). Do not start any task numbered higher than $STOP_AFTER. Still perform the end-of-session housekeeping for whatever you completed."
  fi
  if [[ -n "$STACK" ]]; then
    PROMPT="$PROMPT

IMPORTANT - special instructions for this run: only work tasks annotated [stack: $STACK], including unannotated tasks that continue that stack per the stack-by-default rule. Skip every task in any other stack entirely this run. Still perform the end-of-session housekeeping for whatever you completed."
  fi
  if [[ -n "$EXTRA_INSTRUCTIONS" ]]; then
    PROMPT="$PROMPT

IMPORTANT - special instructions for this run: $EXTRA_INSTRUCTIONS"
  fi
fi

run_repo() {
  local repo_path="$1"
  local name; name="$(basename "$repo_path")"
  local tasks="$repo_path/TASKS.md"

  [[ -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; return 0; }
  grep -Eq '^\s*[0-9]+\.\s*\[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; return 0; }

  echo "=== $name ==="
  git -C "$repo_path" checkout main && git -C "$repo_path" pull

  mkdir -p logs
  local raw_log="logs/$name-$(date +%F).jsonl"
  local readable_log="logs/$name-$(date +%F).log"
  local errlog="logs/$name-$(date +%F).stderr.log"
  claude -p "$PROMPT" \
    --model sonnet \
    --permission-mode acceptEdits \
    --settings .claude/settings.json \
    --add-dir "$repo_path" \
    --output-format stream-json \
    --verbose \
    2>"$errlog" \
    | tee "$raw_log" \
    | jq -r -f format-stream.jq \
    | tee "$readable_log"
}

if [[ -n "$REPO" ]]; then
  TARGET="$REPO"
  [[ -d "$TARGET" ]] || TARGET="$PROJECT_REPOS_DIR/$TARGET"
  run_repo "$TARGET"
else
  [[ -z "$STOP_AFTER$STACK$EXTRA_INSTRUCTIONS$OVERRIDE_PROMPT" ]] || { echo "run flags require a single target repo"; exit 1; }
  for d in "$PROJECT_REPOS_DIR"/*/; do
    run_repo "${d%/}"
  done
fi