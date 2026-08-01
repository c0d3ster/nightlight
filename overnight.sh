#!/bin/bash
# usage: pnpm overnight [repo] [flags]
#   with repo: run that one repo
#   without:   run every repo under PROJECT_REPOS_DIR that has open TASKS.md work
#
# flags (compose with the base prompt, they don't replace it):
#   --stop-after N        only complete tasks through #N (each task's permanent
#                          number, not a count or file position), then stop.
#   --limit N             only complete N tasks this run (a count, not a task
#                          number), then stop.
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
LIMIT=""
STACK=""
EXTRA_INSTRUCTIONS=""
OVERRIDE_PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
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

IMPORTANT - special instructions for this run: only complete tasks up through and including task #$STOP_AFTER (each task's permanent #<n> number, not a count or its position in the file). Do not start any task numbered higher than #$STOP_AFTER. Still perform the end-of-session housekeeping for whatever you completed."
  fi
  if [[ -n "$LIMIT" ]]; then
    PROMPT="$PROMPT

IMPORTANT - special instructions for this run: only complete $LIMIT task(s) this run (a count, not a task number). Stop after finishing the $LIMIT-th task, whichever tasks those turn out to be in file order. Still perform the end-of-session housekeeping for whatever you completed."
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
  grep -Eq '^\s*- \[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; return 0; }

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

  update_stats "$name" "$raw_log"
}

# Rolls this run's cost/duration/turns (from the stream's closing "result"
# event) into stats/<repo>.json's running totals. Local-only, gitignored —
# never committed, never touches the target repo.
update_stats() {
  local name="$1" raw_log="$2"
  mkdir -p stats
  local stats_file="stats/$name.json"
  local result_line; result_line="$(jq -c 'select(.type == "result")' "$raw_log" | tail -n1)"
  if [[ -z "$result_line" ]]; then
    echo "warn: no result event in $raw_log, skipping stats update"
    return 0
  fi
  local prev_json="{}"
  [[ -f "$stats_file" ]] && prev_json="$(cat "$stats_file")"
  jq -n \
    --argjson prev "$prev_json" \
    --argjson result "$result_line" \
    --arg date "$(date +%F)" \
    '{
      sessions: (($prev.sessions // 0) + 1),
      total_cost_usd: (($prev.total_cost_usd // 0) + $result.total_cost_usd),
      total_duration_s: (($prev.total_duration_s // 0) + ($result.duration_ms / 1000 | floor)),
      total_turns: (($prev.total_turns // 0) + $result.num_turns),
      lastRun: {
        date: $date,
        cost_usd: $result.total_cost_usd,
        duration_s: ($result.duration_ms / 1000 | floor),
        num_turns: $result.num_turns
      }
    }' > "$stats_file"
}

if [[ -n "$REPO" ]]; then
  TARGET="$REPO"
  [[ -d "$TARGET" ]] || TARGET="$PROJECT_REPOS_DIR/$TARGET"
  run_repo "$TARGET"
else
  [[ -z "$STOP_AFTER$LIMIT$STACK$EXTRA_INSTRUCTIONS$OVERRIDE_PROMPT" ]] || { echo "run flags require a single target repo"; exit 1; }
  for d in "$PROJECT_REPOS_DIR"/*/; do
    run_repo "${d%/}"
  done
fi