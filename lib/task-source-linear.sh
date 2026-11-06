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
        state { name }
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

# Any open dispatchable work? Prints nothing; exit status is the answer: 0
# eligible, 1 nothing to do, 2 the lookup failed (error already on stderr). Also
# primes the cache ts_list_tasks reads.
# Open Discovered issues also count, so a repo holding only those still reaches
# planning. They stay out of ts_linear_fetch's cache: ts_list_tasks reads it,
# and Discovered items must never be dispatched.
ts_is_eligible() {
  ts_linear_fetch || return 2
  jq -e 'length > 0' "$TS_LINEAR_CACHE" >/dev/null && return 0
  local n; n="$(ts_discovered_count "$1")" || return 2
  [[ "$n" -gt 0 ]]
}

# Prints the number of open Discovered issues; on an API failure prints 0,
# reports the error on stderr and returns 1.
ts_discovered_count() {
  local team_type team_filter resp
  IFS=$'	' read -r team_type team_filter < <(ts_linear_team_filter)
  local gql='query($team: '"$team_type"', $label: String!) {
    issues(first: 100, filter: {
      team: '"$team_filter"',
      state: {type: {nin: ["completed", "canceled"]}},
      labels: {some: {name: {eq: $label}}}
    }) { nodes { identifier } }
  }'
  resp="$(ts_linear_gql "$gql" "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" --arg l "$(ts_linear_label discovered nl:discovered)"     '{team: $t, label: $l}')")" || { echo 0; return 1; }
  jq -r '.data.issues.nodes | length' <<< "$resp"
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

# ---- Issue status (linear.statuses in nightlight-meta.json) ----
# Four phases, each a status name or null (leave the issue alone): queued
# (default null), started ("In Progress"), review ("In Review"), done ("Done").
# queued and started are written here by the runner; review and done by the
# housekeeping prompt. Dispatch never reads status beyond completed/canceled.

TS_LINEAR_STATES_CACHE=""

# Name configured for phase $1, empty when null or unset-with-null-default.
ts_linear_status_for() {
  local phase="$1" default='null'
  case "$phase" in started) default='"In Progress"' ;; review) default='"In Review"' ;; done) default='"Done"' ;; esac
  jq -r --arg k "$phase" --argjson d "$default" '(if has($k) then .[$k] else $d end) // empty' <<< "${TS_LINEAR_STATUSES_JSON:-{\}}"
}

# Prints the team's status id for name $1 (case-insensitive), nothing if the
# team has none. The team's statuses are fetched once per run.
ts_linear_state_id() {
  local name="$1"
  if [[ -z "$TS_LINEAR_STATES_CACHE" || ! -f "$TS_LINEAR_STATES_CACHE" ]]; then
    local team_type team_filter resp
    IFS=$'\t' read -r team_type team_filter < <(ts_linear_team_filter)
    resp="$(ts_linear_gql 'query($team: '"$team_type"') {
      workflowStates(first: 100, filter: {team: '"$team_filter"'}) { nodes { id name } }
    }' "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" '{team: $t}')")" || return 1
    TS_LINEAR_STATES_CACHE="$(mktemp)"
    jq '.data.workflowStates.nodes' <<< "$resp" > "$TS_LINEAR_STATES_CACHE"
  fi
  jq -r --arg n "$name" 'map(select(.name | ascii_downcase == ($n | ascii_downcase))) | first.id // empty' "$TS_LINEAR_STATES_CACHE"
}

# Moves issue $1 to the status named $2. A status the team lacks warns and
# skips (the MCP cannot create statuses); returns 1 on skip or failure.
ts_linear_set_status() {
  local id="$1" name="$2" state_id resp
  state_id="$(ts_linear_state_id "$name")" || return 1
  [[ -n "$state_id" ]] || { echo "warn: team $TS_LINEAR_TEAM_ID has no status named \"$name\", leaving $id as is" >&2; return 1; }
  resp="$(ts_linear_gql 'mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: {stateId: $s}) { success } }' \
    "$(jq -cn --arg i "$id" --arg s "$state_id" '{id: $i, s: $s}')")" || return 1
  jq -e '.data.issueUpdate.success' <<< "$resp" >/dev/null || { echo "warn: couldn't move $id to \"$name\"" >&2; return 1; }
}

# Moves issue $2 to phase $3's status (no-op when the phase is null or the
# issue already has it) and records it in ledger file $1, a JSON object
# {"<id>": {"original": <status before nightlight touched it>, "set": <status>}}.
# An existing entry keeps its original, so a crashed run's issue is not
# recorded as "In Progress" the next time around. Housekeeping restores
# leftovers from the ledger. Status comes from the run's cached listing.
ts_linear_move() {
  local ledger="$1" id="$2" phase="$3" target cur
  target="$(ts_linear_status_for "$phase")"
  [[ -n "$target" ]] || return 0
  cur="$(jq -r --arg i "$id" '.[] | select(.identifier == $i) | .state.name // empty' "$TS_LINEAR_CACHE")"
  [[ -n "$cur" && "$cur" != "$target" ]] || return 0
  ts_linear_set_status "$id" "$target" || return 0
  mkdir -p "$(dirname "$ledger")"
  [[ -s "$ledger" ]] || echo '{}' > "$ledger"
  local tmp; tmp="$(mktemp)"
  jq --arg i "$id" --arg o "$cur" --arg t "$target" '.[$i] = ((.[$i] // {original: $o}) + {set: $t})' "$ledger" > "$tmp" \
    && mv "$tmp" "$ledger" || rm -f "$tmp"
}

# Drops ledger entries whose issue is no longer in a runner-set status
# (queued, started or review names): housekeeping or a person already moved it.
# An API error keeps the entry.
ts_linear_ledger_prune() {
  local ledger="$1" id cur
  [[ -s "$ledger" ]] || return 0
  local sets; sets="$(jq -cn --arg a "$(ts_linear_status_for queued)" --arg b "$(ts_linear_status_for started)" \
    --arg c "$(ts_linear_status_for review)" '[$a, $b, $c] | map(select(. != ""))')"
  while IFS= read -r id; do
    id="${id%$'\r'}"
    cur="$(ts_linear_gql 'query($id: String!) { issue(id: $id) { state { name } } }' "$(jq -cn --arg i "$id" '{id: $i}')" \
      | jq -r '.data.issue.state.name // empty')" || continue
    [[ -n "$cur" ]] || continue
    jq -e --arg c "$cur" 'index($c)' <<< "$sets" >/dev/null && continue
    local tmp; tmp="$(mktemp)"
    jq --arg i "$id" 'del(.[$i])' "$ledger" > "$tmp" && mv "$tmp" "$ledger" || rm -f "$tmp"
  done < <(jq -r 'keys[]' "$ledger")
}

# Optional grouping hooks (docs/plans/multi-task-source.md 2.6). A Linear
# milestone lives inside a Project and is created only by /plan-tasks through
# the MCP tools (save_project, save_milestone, save_issue), so the shell side
# has nothing to do: both stay no-ops, and callers need no declare -F guard.
# save_milestone has no state parameter, so Linear derives a milestone's
# completed or open status from its issues; there is nothing to close or reopen.
ts_ensure_group() { return 0; }
ts_close_group() { return 0; }

# ---- Stack notes held by the tracker (docs/plans/multi-task-source.md 2.7) ----
# One Linear document per non-solo stack, titled "stack-notes: <stack>", attached
# to the stack's project (found through its milestone, see /plan-tasks) or, with
# no project, to the team. Each task appends its entry with save_document's
# atomic append patch. A finished stack's document is retitled
# "[done] stack-notes: <stack>". Reads are GraphQL here; writes stay in the
# claude -p subprocess (MCP).

# Writes <dir>/<stack>.md (the document content) and <dir>/<stack>.ref (one line
# naming the document) for each stack-notes document of this team, or just stack
# $3 when given. Documents of other teams are ignored (matched through the
# document's team or its project's teams). Fails on an API error.
ts_stack_notes_export() {
  local repo_path="$1" dir="$2" only="${3:-}"
  [[ -n "${LINEAR_API_KEY:-}" ]] || { echo "error: LINEAR_API_KEY is not set" >&2; return 1; }
  mkdir -p "$dir"
  local needle="stack-notes: ${only}" resp
  resp="$(ts_linear_gql 'query($q: String!) {
    documents(first: 100, filter: {title: {containsIgnoreCase: $q}}) {
      nodes { id title content team { key } project { teams { nodes { key } } } }
    }
  }' "$(jq -cn --arg q "$needle" '{q: $q}')")" || return 1
  local team_key="$TS_LINEAR_TEAM_ID" stack
  # Rows: stack, tab, base64 of the document JSON (content has newlines).
  while IFS=$'\t' read -r stack row; do
    stack="${stack%$'\r'}"
    [[ -n "$stack" ]] || continue
    [[ -z "$only" || "$stack" == "$only" ]] || continue
    printf '%s' "$row" | base64 -d | jq -r '.content // ""' | tr -d '\r' > "$dir/$stack.md"
    printf '%s' "$row" | base64 -d | jq -r '"document \(.id), currently titled \"\(.title)\""' > "$dir/$stack.ref"
  done < <(jq -r --arg t "$team_key" '
    .data.documents.nodes[]
    | select(.title | test("^([[]done[]] )?stack-notes: "))
    | select((.team.key // "") == $t or ([.project.teams.nodes[]?.key] | index($t)) != null or (.team == null and .project == null))
    | "\(.title | sub("^[[]done[]] "; "") | sub("^stack-notes: "; ""))\t\(. | @json | @base64 | gsub("\n"; ""))"' <<< "$resp")
}

# Prompt text telling a task session how to write its stack-notes entry.
# $1 stack, $2 ref line from ts_stack_notes_export (empty: no document yet).
ts_stack_notes_write_instructions() {
  local stack="$1" ref="${2:-}"
  if [[ -z "$ref" ]]; then
    printf '%s' "Stack notes live in the tracker, not in a file. No notes document exists for this stack yet: find the stack's Linear Project through its milestone (list_projects with includeMilestones, team $TS_LINEAR_TEAM_ID, the milestone named \"$stack\") and create the document with save_document (title \"stack-notes: $stack\", project <that project>, content your entry). If the stack has no Project or milestone, attach it to the team instead (team $TS_LINEAR_TEAM_ID), and never create a Project yourself."
    return 0
  fi
  printf '%s' "Stack notes live in the tracker, not in a file: the notes are $ref. Add your entry with ONE save_document call on that id using patch [{op: \"append\", text: \"\n\n<your entry>\"}] (never resend or edit earlier content). If its title starts with \"[done] \" (the stack was finished and is now resumed), also pass title \"stack-notes: $stack\" in that same call."
}

# Counts for stats.sh: prints "<overnight> <manual> <blocked>". overnight =
# completed issues labelled nl:overnight; manual = completed issues with a
# section label but no nl:overnight; blocked = open issues labelled nl:blocked.
# Pages through every result (100 per page).
ts_stats_counts() {
  [[ -n "${LINEAR_API_KEY:-}" ]] || { echo "error: LINEAR_API_KEY is not set" >&2; return 1; }
  local team_type team_filter
  IFS=$'\t' read -r team_type team_filter < <(ts_linear_team_filter)
  local overnight_label blocked_label sections
  overnight_label="$(ts_linear_label overnight nl:overnight)"
  blocked_label="$(ts_linear_label blocked nl:blocked)"
  sections="$(jq -cn --arg a "$(ts_linear_label agentReady nl:agent-ready)" \
    --arg v "$(ts_linear_label verify nl:verify)" --arg r "$(ts_linear_label research nl:research)" --arg o "$overnight_label" '[$a, $v, $r, $o]')"
  local query='query($team: '"$team_type"', $labels: [String!], $after: String, $state: StringComparator) {
    issues(first: 100, after: $after, filter: {
      team: '"$team_filter"',
      state: {type: $state},
      labels: {some: {name: {in: $labels}}}
    }) {
      pageInfo { hasNextPage endCursor }
      nodes { identifier labels { nodes { name } } }
    }
  }'
  local closed="" blocked=0 after resp
  # Closed: completed-type issues, paged.
  after=""
  while :; do
    resp="$(ts_linear_gql "$query" "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" --argjson l "$sections" --arg a "$after" \
      '{team: $t, labels: $l, state: {eq: "completed"}} + (if $a == "" then {} else {after: $a} end)')")" || return 1
    closed="$closed$(jq -c '.data.issues.nodes[]' <<< "$resp")"$'\n'
    jq -e '.data.issues.pageInfo.hasNextPage' <<< "$resp" >/dev/null || break
    after="$(jq -r '.data.issues.pageInfo.endCursor' <<< "$resp")"
  done
  # Blocked: not completed or canceled, labelled nl:blocked, paged.
  local bquery='query($team: '"$team_type"', $label: String!, $after: String) {
    issues(first: 100, after: $after, filter: {
      team: '"$team_filter"',
      state: {type: {nin: ["completed", "canceled"]}},
      labels: {some: {name: {eq: $label}}}
    }) { pageInfo { hasNextPage endCursor } nodes { identifier } }
  }'
  after=""
  while :; do
    resp="$(ts_linear_gql "$bquery" "$(jq -cn --arg t "$TS_LINEAR_TEAM_ID" --arg l "$blocked_label" --arg a "$after" \
      '{team: $t, label: $l} + (if $a == "" then {} else {after: $a} end)')")" || return 1
    blocked=$((blocked + $(jq '.data.issues.nodes | length' <<< "$resp")))
    jq -e '.data.issues.pageInfo.hasNextPage' <<< "$resp" >/dev/null || break
    after="$(jq -r '.data.issues.pageInfo.endCursor' <<< "$resp")"
  done
  jq -rs --arg o "$overnight_label" --argjson b "$blocked" '
    unique_by(.identifier) as $all
    | ($all | map(select([.labels.nodes[].name] | index($o))) | length) as $ov
    | "\($ov) \(($all | length) - $ov) \($b)"' <<< "$closed"
}
