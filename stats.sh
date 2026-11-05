#!/usr/bin/env bash
# usage: pnpm stats [repo] — cost/time totals from stats/*.json
#   with repo: that repo's running totals
#   without:   summed across every repo worked from this nightlight instance
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
[[ -f .env ]] && { set -a; source .env; set +a; }
source lib/task-source.sh

# task_counts <repo-name>: prints the repo's task counts as one JSON object, or
# nothing when the repo dir or its tracker is unreachable (stats stay usable
# offline). Remote sources ask the tracker, local reads the meta file:
#   remote: {source, overnight, manual, blocked}   local: {source, completed, blocked}
task_counts() {
  local name="$1" path
  if [[ "$name" == "$(basename "$PWD")" ]]; then path="."; else path="${PROJECT_REPOS_DIR:-}/$name"; fi
  [[ -d "$path" ]] || return 0
  (
    load_task_source "$path" >/dev/null 2>&1 || exit 0
    if [[ "$TASK_SOURCE" == local ]]; then
      jq -c '{source: "local", completed: (.tasksCompleted // 0), blocked: (.tasksBlocked // 0)}' "$path/docs/nightlight-meta.json" 2>/dev/null
      exit 0
    fi
    read -r ov man blk < <(ts_stats_counts "$path" 2>/dev/null) || exit 0
    [[ -n "${blk:-}" ]] || exit 0
    jq -cn --arg s "$TASK_SOURCE" --argjson o "$ov" --argjson m "$man" --argjson b "$blk" '{source: $s, overnight: $o, manual: $m, blocked: $b}'
  )
}

if [[ -n "$1" ]]; then
  FILE="stats/$1.json"
  [[ -f "$FILE" ]] || { echo "no stats for $1"; exit 1; }
  counts="$(task_counts "$1")"
  if [[ -n "$counts" ]]; then jq --argjson t "$counts" '. + {tasks: $t}' "$FILE"; else cat "$FILE"; fi
else
  # Tracker counts summed over every repo that has stats and is reachable.
  all_counts="[]"
  for f in stats/*.json; do
    [[ -e "$f" ]] || continue
    c="$(task_counts "$(basename "$f" .json)")"
    [[ -n "$c" ]] && all_counts="$(jq -c --argjson c "$c" '. + [$c]' <<< "$all_counts")"
  done
  jq -s --argjson tc "$all_counts" '{
    repos: length,
    sessions: (map(.sessions) | add // 0),
    total_cost_usd: (map(.total_cost_usd) | add // 0),
    total_duration_s: (map(.total_duration_s) | add // 0),
    total_turns: (map(.total_turns) | add // 0),
    total_cache_read_tokens: (map(.total_cache_read_tokens // 0) | add // 0),
    total_cache_creation_tokens: (map(.total_cache_creation_tokens // 0) | add // 0),
    total_input_tokens: (map(.total_input_tokens // 0) | add // 0),
    total_output_tokens: (map(.total_output_tokens // 0) | add // 0),
    tasks: {
      overnight: ($tc | map(.overnight // .completed // 0) | add // 0),
      manual: ($tc | map(.manual // 0) | add // 0),
      blocked: ($tc | map(.blocked // 0) | add // 0),
      repos_counted: ($tc | length)
    }
  }' stats/*.json 2>/dev/null
fi
