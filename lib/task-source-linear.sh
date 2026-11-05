#!/usr/bin/env bash
# Linear task source: tasks are open issues on one team carrying an nl:* section
# label. Sourced by overnight.sh's run_repo(); see docs/plans/multi-task-source.md
# Phase 3 for the design and the ts_* contract in Phase 1.2. Needs LINEAR_API_KEY
# (resolved with env_get in lib/env.sh) and TS_LINEAR_TEAM_ID (team key like ENG, or a team UUID).

# Ids are Linear identifiers (ENG-142), so --stop-after is rejected.
TS_NUMERIC_IDS=0

TS_LINEAR_URL="${TS_LINEAR_URL:-https://api.linear.app/graphql}"

# One query per run: ts_is_eligible fetches and caches the merged, filtered,
# creation-ordered issue list here; ts_list_tasks reads the same file.
TS_LINEAR_CACHE=""

# Label names, overridable via the labels block in nightlight-meta.json.
ts_linear_label() {
  local key="$1" default="$2"
  jq -r --arg k "$key" --arg d "$default" '.[$k] // $d' <<< "${TS_LABELS_JSON:-{\}}"
}

# Prints "<variable type>\t<team filter>" for $TS_LINEAR_TEAM_ID. A UUID filters
# on the team's id, whose comparator is typed ID; a team key (ENG) filters on
# key, typed String. Declaring $team with the wrong type is a GraphQL error.
ts_linear_team_filter() {
  if [[ "$TS_LINEAR_TEAM_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    printf '%s\t%s' 'ID!' '{id: {eq: $team}}'
  else
    printf '%s\t%s' 'String!' '{key: {eq: $team}}'
  fi
}

# POSTs a GraphQL query ($1) with variables JSON ($2) and prints the response
# body. Fails on HTTP errors and on a GraphQL "errors" array.
ts_linear_gql() {
  local query="$1" vars="${2:-{\}}" payload resp
  payload="$(jq -cn --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')" || return 1
  resp="$(curl -sS --fail-with-body -X POST "$TS_LINEAR_URL" \
    -H "Content-Type: application/json" -H "Authorization: $LINEAR_API_KEY" \
    --data "$payload")" \
    || { echo "error: Linear API request failed: $resp" >&2; return 1; }
  if jq -e '.errors' <<< "$resp" >/dev/null 2>&1; then
    echo "error: Linear API returned errors: $(jq -c '.errors' <<< "$resp")" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# Fetches open (not completed/canceled) team issues carrying any section label
# in one query, drops blocked and needs-human, and orders them: creation time
# within a stack, Linear priority between stacks and solo tasks (a stack takes
# its best member's priority, unprioritized last, ties by creation time). No-op
# if already cached this run.
ts_linear_fetch() {
  [[ -n "$TS_LINEAR_CACHE" && -f "$TS_LINEAR_CACHE" ]] && return 0
  [[ -n "${LINEAR_API_KEY:-}" ]] || { echo "error: LINEAR_API_KEY is not set" >&2; return 1; }
  local blocked needs_human stack_prefix sections
  blocked="$(ts_linear_label blocked nl:blocked)"
  needs_human="$(ts_linear_label needsHuman nl:needs-human)"
  stack_prefix="$(ts_linear_label stackPrefix nl:stack:)"
  sections="$(jq -cn --arg a "$(ts_linear_label agentReady nl:agent-ready)" \
    --arg v "$(ts_linear_label verify nl:verify)" --arg r "$(ts_linear_label research nl:research)" '[$a, $v, $r]')"

  local team_type team_filter
  IFS=$'\t' read -r team_type team_filter < <(ts_linear_team_filter)
  local query='query($team: '"$team_type"', $labels: [String!], $after: String) {
    issues(first: 100, after: $after, orderBy: createdAt, filter: {
      team: '"$team_filter"',
      state: {type: {nin: ["completed", "canceled"]}},
      labels: {some: {name: {in: $labels}}}
    }) {
      pageInfo { hasNextPage endCursor }
      nodes {
        identifier title description createdAt priority
        labels { nodes { name } }
        comments { nodes { body user { name } } }
      }
    }
  }'

  local raw; raw="$(mktemp)"
  local after="" resp
  while :; do
    resp="$(ts_linear_gql "$query" "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" --argjson l "$sections" --arg a "$after" \
      '{team: $t, labels: $l} + (if $a == "" then {} else {after: $a} end)')")" \
      || { rm -f "$raw"; return 1; }
    jq -c '.data.issues.nodes[]' <<< "$resp" >> "$raw"
    jq -e '.data.issues.pageInfo.hasNextPage' <<< "$resp" >/dev/null || break
    after="$(jq -r '.data.issues.pageInfo.endCursor' <<< "$resp")"
  done

  TS_LINEAR_CACHE="$(mktemp)"
  jq -s --arg b "$blocked" --arg n "$needs_human" --arg p "$stack_prefix" '
    map(select(([.labels.nodes[].name] | index($b) | not) and ([.labels.nodes[].name] | index($n) | not)))
    | map(. + {stack: ([.labels.nodes[].name | select(startswith($p)) | ltrimstr($p)] | first // null)})
    | sort_by(.createdAt)
    # Resolve inherited stacks in creation order, before any regrouping.
    | reduce .[] as $i ({prev: "solo", out: []};
        ($i.stack // .prev) as $s | .prev = $s | .out += [$i + {stack: $s}])
    | .out
    # Priority orders whole groups, never tasks inside a stack: each non-solo
    # stack is one group ranked by its best member, each solo task its own group.
    # Linear priority is 1 urgent .. 4 low, 0 none; none ranks last.
    | map(. + {gk: (if .stack == "solo" then "solo:" + .identifier else .stack end),
               rank: (if (.priority // 0) == 0 then 5 else .priority end)})
    | (group_by(.gk) | map({key: .[0].gk, value: {rank: (map(.rank) | min), first: (map(.createdAt) | min)}}) | from_entries) as $g
    | sort_by([$g[.gk].rank, $g[.gk].first, .createdAt])
  ' "$raw" > "$TS_LINEAR_CACHE" || { rm -f "$raw" "$TS_LINEAR_CACHE"; TS_LINEAR_CACHE=""; return 1; }
  rm -f "$raw"
}

# Any open dispatchable work? Prints nothing; exit status is the answer. Also
# primes the cache ts_list_tasks reads.
ts_is_eligible() {
  ts_linear_fetch || return 1
  jq -e 'length > 0' "$TS_LINEAR_CACHE" >/dev/null
}

# Writes one synthesized block file per issue under $2 (clearing anything
# already there) and prints "<identifier>\t<effective-stack>\t<blockfile>"
# lines in dispatch order (see ts_linear_fetch). Effective stack is the
# nl:stack:* label, else the previous task's stack in creation order (solo if
# none yet). Comments come from workspace users.
ts_list_tasks() {
  local outdir="$2"
  mkdir -p "$outdir"
  rm -f "$outdir"/*.task
  ts_linear_fetch || return 1

  local idx=0 prev_stack="" id stack file
  while IFS=$'\t' read -r id stack; do
    id="${id%$'\r'}"; stack="${stack%$'\r'}"
    [[ "$stack" == "null" || -z "$stack" ]] && stack="${prev_stack:-solo}"
    prev_stack="$stack"
    idx=$((idx+1))
    file="$outdir/$(printf '%04d' "$idx")-$id.task"
    jq -r --arg id "$id" --arg s "$stack" '
      .[] | select(.identifier == $id)
      | "- [ ] \(.identifier) [stack: \($s)] \(.title)\n\n\(.description // "")"
        + ([.comments.nodes[]?
            | "\n\n### Comment by \(.user.name // "unknown")\n\n\(.body // "")"] | join(""))
    ' "$TS_LINEAR_CACHE" | tr -d '\r' > "$file"
    printf '%s\t%s\t%s\n' "$id" "$stack" "$file"
  done < <(jq -r '.[] | "\(.identifier)\t\(.stack // "")"' "$TS_LINEAR_CACHE")
}

# How this source writes a task id in the TASK_RESULT line: the bare identifier.
ts_task_result_label() {
  printf '%s' "$1"
}

# Regex (ERE) matching this task's own TASK_RESULT line, anchored at line start.
ts_task_result_re() {
  local id="$1"
  printf '%s' "^TASK_RESULT: $(ts_task_result_label "$id") "
}

# Open and closed issues whose title or description contain $2. Prints
# "<state>\t<identifier>\t<title>", state being open or closed.
ts_find_related() {
  local query="$2"
  [[ -n "${LINEAR_API_KEY:-}" ]] || { echo "error: LINEAR_API_KEY is not set" >&2; return 1; }
  local team_type team_filter
  IFS=$'\t' read -r team_type team_filter < <(ts_linear_team_filter)
  local gql='query($team: '"$team_type"', $q: String!) {
    issues(first: 30, orderBy: updatedAt, filter: {
      team: '"$team_filter"',
      or: [{title: {containsIgnoreCase: $q}}, {description: {containsIgnoreCase: $q}}]
    }) { nodes { identifier title state { type } } }
  }'
  local resp
  resp="$(ts_linear_gql "$gql" "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" --arg q "$query" '{team: $t, q: $q}')")" || return 1
  jq -r '.data.issues.nodes[]
    | "\(if .state.type == "completed" or .state.type == "canceled" then "closed" else "open" end)\t\(.identifier)\t\(.title)"' <<< "$resp"
}

# Optional grouping hooks (docs/plans/multi-task-source.md 2.6): this source
# has no milestone object, so both are no-ops. Callers need no declare -F guard.
ts_ensure_group() { return 0; }
ts_close_group() { return 0; }
