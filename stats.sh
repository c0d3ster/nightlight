#!/usr/bin/env bash
# usage: pnpm stats [repo] — cost/time totals from stats/*.json
#   with repo: that repo's running totals
#   without:   summed across every repo worked from this nightlight instance
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }

if [[ -n "$1" ]]; then
  FILE="stats/$1.json"
  [[ -f "$FILE" ]] || { echo "no stats for $1"; exit 1; }
  cat "$FILE"
else
  jq -s '{
    repos: length,
    sessions: (map(.sessions) | add // 0),
    total_cost_usd: (map(.total_cost_usd) | add // 0),
    total_duration_s: (map(.total_duration_s) | add // 0),
    total_turns: (map(.total_turns) | add // 0),
    total_cache_read_tokens: (map(.total_cache_read_tokens // 0) | add // 0),
    total_cache_creation_tokens: (map(.total_cache_creation_tokens // 0) | add // 0)
  }' stats/*.json 2>/dev/null
fi
