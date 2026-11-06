#!/usr/bin/env bash
# GitHub Issues task source: tasks are open issues carrying an nl:* section
# label. Sourced by overnight.sh's run_repo(); see docs/plans/multi-task-source.md
# Phase 2 for the design and the ts_* contract in Phase 1.2.

# --stop-after compares ids numerically; issue numbers are plain integers.
TS_NUMERIC_IDS=1

# One query per run: ts_is_eligible fetches and caches the merged, filtered,
# dispatch-ordered issue list here; ts_list_tasks reads the same file.
TS_GH_CACHE=""

# Label names, overridable via the labels block in nightlight-meta.json.
ts_gh_label() {
  local key="$1" default="$2"
  jq -r --arg k "$key" --arg d "$default" '.[$k] // $d' <<< "${TS_LABELS_JSON:-{\}}"
}

# Prints a one-line error naming the repo and classifying gh's stderr ($2) as
# an auth, repo or network failure, followed by gh's own message.
ts_gh_explain() {
  local what="$1" err="$2" kind="gh failed"
  if grep -qiE 'gh auth login|not logged in|authentication|bad credentials|HTTP 401|GH_TOKEN' <<< "$err"; then
    kind="authentication failed (run gh auth login or set GH_TOKEN)"
  elif grep -qiE 'could not resolve host|no such host|dial tcp|timed out|timeout|connection (refused|reset)|network is unreachable|error connecting' <<< "$err"; then
    kind="network error"
  elif grep -qiE 'could not resolve to a repository|HTTP 404|not found' <<< "$err"; then
    kind="repo not found or no access (check github.repo in docs/nightlight-meta.json)"
  fi
  echo "error: GitHub ${TS_GITHUB_REPO:-<unresolved repo>}: $what: $kind: ${err//$'
'/ }" >&2
}

# Sets TS_GITHUB_REPO to github.repo, else the target repo's origin.
ts_gh_resolve_repo() {
  [[ -n "$TS_GITHUB_REPO" ]] && return 0
  local out err; err="$(mktemp)"
  if out="$(cd "$1" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$err")" && [[ -n "$out" ]]; then
    TS_GITHUB_REPO="$out"; rm -f "$err"; return 0
  fi
  ts_gh_explain "can't resolve the repo from origin (or set github.repo in docs/nightlight-meta.json)" "$(cat "$err")"
  rm -f "$err"
  return 1
}

# Fetches open issues for each section label once, merges, drops blocked and
# needs-human, and orders them: issue number within a stack, priority label
# between groups (a non-solo stack is one group ranked by its best member, each
# solo task its own group; high first, unlabeled next, low last; ties by lowest
# issue number). Inherited stacks resolve in number order before regrouping.
# No-op if already cached this run.
ts_gh_fetch() {
  local repo_path="$1"
  [[ -n "$TS_GH_CACHE" && -f "$TS_GH_CACHE" ]] && return 0
  ts_gh_resolve_repo "$repo_path" || return 1
  local sections=("$(ts_gh_label agentReady nl:agent-ready)" "$(ts_gh_label verify nl:verify)" "$(ts_gh_label research nl:research)")
  local blocked needs_human stack_prefix prio_high prio_low
  prio_high="$(ts_gh_label priorityHigh nl:priority:high)"
  prio_low="$(ts_gh_label priorityLow nl:priority:low)"
  blocked="$(ts_gh_label blocked nl:blocked)"
  needs_human="$(ts_gh_label needsHuman nl:needs-human)"
  stack_prefix="$(ts_gh_label stackPrefix nl:stack:)"

  local raw; raw="$(mktemp)"
  local label
  for label in "${sections[@]}"; do
    gh issue list --repo "$TS_GITHUB_REPO" --state open --label "$label" --limit 200 \
      --json number,title,body,labels,author,comments,createdAt >> "$raw" \
      || { echo "error: gh issue list failed for label $label" >&2; rm -f "$raw"; return 1; }
  done

  TS_GH_CACHE="$(mktemp)"
  jq -s --arg b "$blocked" --arg n "$needs_human" --arg p "$stack_prefix" --arg ph "$prio_high" --arg pl "$prio_low" '
    add
    | unique_by(.number)
    | map(select(([.labels[].name] | index($b) | not) and ([.labels[].name] | index($n) | not)))
    | map(. + {stack: ([.labels[].name | select(startswith($p)) | ltrimstr($p)] | first // null)})
    | sort_by(.number)
    | reduce .[] as $i ({prev: "solo", out: []};
        ($i.stack // .prev) as $s | .prev = $s | .out += [$i + {stack: $s}])
    | .out
    | map(. + {gk: (if .stack == "solo" then "solo:\(.number)" else .stack end),
               rank: (([.labels[].name] | if index($ph) then 0 elif index($pl) then 2 else 1 end))})
    | (group_by(.gk) | map({key: .[0].gk, value: {rank: (map(.rank) | min), first: (map(.number) | min)}}) | from_entries) as $g
    | sort_by([$g[.gk].rank, $g[.gk].first, .number])
  ' "$raw" > "$TS_GH_CACHE" || { rm -f "$raw" "$TS_GH_CACHE"; TS_GH_CACHE=""; return 1; }
  rm -f "$raw"
}

# Any open dispatchable work? Prints nothing; exit status is the answer: 0
# eligible, 1 nothing to do, 2 the lookup failed (error already on stderr). Also
# primes the cache ts_list_tasks reads.
# Open Discovered issues also count, so a repo holding only those still reaches
# planning. They stay out of ts_gh_fetch's cache: ts_list_tasks reads it, and
# Discovered items must never be dispatched.
ts_is_eligible() {
  ts_gh_fetch "$1" || return 2
  jq -e 'length > 0' "$TS_GH_CACHE" >/dev/null && return 0
  local n; n="$(ts_discovered_count "$1")" || return 2
  [[ "$n" -gt 0 ]]
}

# Prints the number of open Discovered issues; on a gh failure prints 0, reports
# the error on stderr and returns 1.
ts_discovered_count() {
  local out err; err="$(mktemp)"
  ts_gh_resolve_repo "$1" || { rm -f "$err"; echo 0; return 1; }
  if out="$(gh issue list --repo "$TS_GITHUB_REPO" --state open --label "$(ts_gh_label discovered nl:discovered)" \
    --limit 200 --json number --jq length 2>"$err")"; then
    rm -f "$err"; echo "$out"; return 0
  fi
  ts_gh_explain "gh issue list failed for the discovered label" "$(cat "$err")"
  rm -f "$err"; echo 0; return 1
}

# Writes one synthesized block file per issue under $2 (clearing anything
# already there) and prints "<number>\t<effective-stack>\t<blockfile>"
# lines in dispatch order (see ts_gh_fetch). Effective stack is the nl:stack:*
# label, else the previous task's stack (solo if none yet), resolved in fetch. Only OWNER/MEMBER/COLLABORATOR
# comments make it into the block; the issue body is included as-is since the
# section label (which needs triage access to apply) is the gate.
ts_list_tasks() {
  local repo_path="$1" outdir="$2"
  mkdir -p "$outdir"
  rm -f "$outdir"/*.task
  ts_gh_fetch "$repo_path" || return 1

  local idx=0 num stack file
  while IFS=$'\t' read -r num stack; do
    num="${num%$'\r'}"; stack="${stack%$'\r'}"
    idx=$((idx+1))
    file="$outdir/$(printf '%04d' "$idx")-$num.task"
    jq -r --argjson n "$num" --arg s "$stack" '
      .[] | select(.number == $n)
      | "- [ ] #\(.number) [stack: \($s)] \(.title)\n\n\(.body // "")"
        + ([.comments[]?
            | select(.authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR")
            | "\n\n### Comment by \(.author.login // "unknown")\n\n\(.body // "")"] | join(""))
    ' "$TS_GH_CACHE" | tr -d '\r' > "$file"
    printf '%s\t%s\t%s\n' "$num" "$stack" "$file"
  done < <(jq -r '.[] | "\(.number)\t\(.stack)"' "$TS_GH_CACHE")
}

# How this source writes a task id in the TASK_RESULT line the prompt asks for.
ts_task_result_label() {
  printf '%s' "#$1"
}

# Regex (ERE) matching this task's own TASK_RESULT line, anchored at line start.
ts_task_result_re() {
  local id="$1"
  printf '%s' "^TASK_RESULT: $(ts_task_result_label "$id") "
}

# Open and closed issues whose title or body match $2. Prints
# "<state>\t#<n>\t<title>", state being open or closed.
ts_find_related() {
  local repo_path="$1" query="$2"
  ts_gh_resolve_repo "$repo_path" || return 1
  gh issue list --repo "$TS_GITHUB_REPO" --state all --search "$query" --limit 30 \
    --json number,title,state \
    --jq '.[] | "\(.state | ascii_downcase)\t#\(.number)\t\(.title)"'
}

# Prints "<number> <state>" for the milestone titled $1 (any state), or nothing.
# Title equals the stack name.
ts_gh_milestone_lookup() {
  local title="$1"
  gh api "repos/$TS_GITHUB_REPO/milestones?state=all&per_page=100" --paginate 2>/dev/null \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | "\(.number) \(.state)"' | head -n1
}

# Ensures an open milestone titled after stack $2 exists: creates it (with
# description $3) if missing, reopens it if closed. No-op for solo. Idempotent.
# The nl:stack label is authoritative for dispatch, so a gh failure warns and
# returns 0.
ts_ensure_group() {
  local repo_path="$1" stack="$2" desc="${3:-}"
  [[ -z "$stack" || "$stack" == "solo" ]] && return 0
  ts_gh_resolve_repo "$repo_path" || return 0
  local found num state
  found="$(ts_gh_milestone_lookup "$stack")"
  if [[ -z "$found" ]]; then
    gh api -X POST "repos/$TS_GITHUB_REPO/milestones" -f title="$stack" -f description="$desc" >/dev/null 2>&1 \
      || echo "warning: couldn't create milestone \"$stack\"; continuing (the label is authoritative)" >&2
    return 0
  fi
  read -r num state <<< "$found"
  [[ "$state" == "open" ]] && return 0
  gh api -X PATCH "repos/$TS_GITHUB_REPO/milestones/$num" -f state=open >/dev/null 2>&1 \
    || echo "warning: couldn't reopen milestone \"$stack\"; continuing (the label is authoritative)" >&2
  return 0
}

# Closes the milestone titled after stack $2. No-op for solo, a missing
# milestone, or one already closed. Idempotent; failures warn and return 0.
ts_close_group() {
  local repo_path="$1" stack="$2"
  [[ -z "$stack" || "$stack" == "solo" ]] && return 0
  ts_gh_resolve_repo "$repo_path" || return 0
  local found num state
  found="$(ts_gh_milestone_lookup "$stack")"
  [[ -z "$found" ]] && return 0
  read -r num state <<< "$found"
  [[ "$state" == "closed" ]] && return 0
  gh api -X PATCH "repos/$TS_GITHUB_REPO/milestones/$num" -f state=closed >/dev/null 2>&1 \
    || echo "warning: couldn't close milestone \"$stack\"; continuing (the label is authoritative)" >&2
  return 0
}

# ---- Stack notes held by the tracker (docs/plans/multi-task-source.md 2.7) ----
# One tracking issue per non-solo stack, titled "stack-notes: <stack>" and
# labelled nl:stack-notes (no section label, so it is never dispatched or
# counted). Each task appends its entry as one comment. A finished stack's issue
# is retitled "[done] stack-notes: <stack>" and stays open.

# Writes <dir>/<stack>.md (every comment body, oldest first, blank-line
# separated) and <dir>/<stack>.ref (one line naming the tracking issue) for each
# stack-notes issue, or just stack $3 when given. Writes nothing for a stack
# with no issue. Fails if gh does.
ts_stack_notes_export() {
  local repo_path="$1" dir="$2" only="${3:-}"
  ts_gh_resolve_repo "$repo_path" || return 1
  mkdir -p "$dir"
  local raw
  raw="$(gh issue list --repo "$TS_GITHUB_REPO" --state all --label "$(ts_gh_label stackNotes nl:stack-notes)" --limit 200 \
    --json number,title,comments)" || return 1
  local stack
  while IFS= read -r stack; do
    stack="${stack%$'\r'}"
    [[ -n "$stack" ]] || continue
    [[ -z "$only" || "$stack" == "$only" ]] || continue
    jq -r --arg s "$stack" '
      [.[] | select((.title | sub("^[[]done[]] "; "") | sub("^stack-notes: "; "")) == $s)] | first
      | [.comments[]?.body] | join("\n\n")' <<< "$raw" | tr -d '\r' > "$dir/$stack.md"
    jq -r --arg s "$stack" '
      [.[] | select((.title | sub("^[[]done[]] "; "") | sub("^stack-notes: "; "")) == $s)] | first
      | "issue #\(.number), currently titled \"\(.title)\""' <<< "$raw" > "$dir/$stack.ref"
  done < <(jq -r '.[] | select(.title | test("^([[]done[]] )?stack-notes: ")) | .title | sub("^[[]done[]] "; "") | sub("^stack-notes: "; "")' <<< "$raw")
}

# Prompt text telling a task session how to write its stack-notes entry.
# $1 stack, $2 ref line from ts_stack_notes_export (empty: no issue yet).
ts_stack_notes_write_instructions() {
  local stack="$1" ref="${2:-}" label repo_flag=""
  label="$(ts_gh_label stackNotes nl:stack-notes)"
  [[ -n "$TS_GITHUB_REPO" ]] && repo_flag=" --repo $TS_GITHUB_REPO"
  if [[ -z "$ref" ]]; then
    printf '%s' "Stack notes live in the tracker, not in a file. No tracking issue exists for this stack yet: create it with \`gh issue create$repo_flag --title \"stack-notes: $stack\" --label $label --body \"Stack notes for $stack. One comment per task; do not edit.\"\` (create the label first with \`gh label create $label$repo_flag\` if the repo lacks it, and give the issue no other labels), then post your entry as a comment with \`gh issue comment <number>$repo_flag --body-file <file>\`."
    return 0
  fi
  printf '%s' "Stack notes live in the tracker, not in a file: the tracking issue is $ref. Post your entry as ONE new comment with \`gh issue comment <number>$repo_flag --body-file <file>\` (never edit earlier comments). If its title starts with \"[done] \" (the stack was finished and is now resumed), also drop that prefix with \`gh issue edit <number>$repo_flag --title \"stack-notes: $stack\"\`."
}

# Counts for stats.sh: prints "<overnight> <manual> <blocked>". overnight =
# closed issues labelled nl:overnight; manual = closed issues with a section
# label but no nl:overnight; blocked = open issues labelled nl:blocked.
ts_stats_counts() {
  local repo_path="$1"
  ts_gh_resolve_repo "$repo_path" || return 1
  local overnight_label blocked_label
  overnight_label="$(ts_gh_label overnight nl:overnight)"
  blocked_label="$(ts_gh_label blocked nl:blocked)"
  local closed="" label raw
  for label in "$(ts_gh_label agentReady nl:agent-ready)" "$(ts_gh_label verify nl:verify)" "$(ts_gh_label research nl:research)" "$overnight_label"; do
    raw="$(gh issue list --repo "$TS_GITHUB_REPO" --state closed --label "$label" --limit 10000 --json number,labels)" || return 1
    closed="$closed$raw"
  done
  local blocked
  blocked="$(gh issue list --repo "$TS_GITHUB_REPO" --state open --label "$blocked_label" --limit 10000 --json number --jq length)" || return 1
  jq -rs --arg o "$overnight_label" --argjson b "$blocked" '
    (add // []) | unique_by(.number) as $all
    | ($all | map(select([.labels[].name] | index($o))) | length) as $ov
    | "\($ov) \(($all | length) - $ov) \($b)"' <<< "$closed"
}
