#!/usr/bin/env bash
# GitHub Issues task source: tasks are open issues carrying an nl:* section
# label. Sourced by overnight.sh's run_repo(); see docs/plans/multi-task-source.md
# Phase 2 for the design and the ts_* contract in Phase 1.2.

# --stop-after compares ids numerically; issue numbers are plain integers.
TS_NUMERIC_IDS=1

# One query per run: ts_is_eligible fetches and caches the merged, filtered,
# number-sorted issue list here; ts_list_tasks reads the same file.
TS_GH_CACHE=""

# Label names, overridable via the labels block in nightlight-meta.json.
ts_gh_label() {
  local key="$1" default="$2"
  jq -r --arg k "$key" --arg d "$default" '.[$k] // $d' <<< "${TS_LABELS_JSON:-{\}}"
}

# Sets TS_GITHUB_REPO to github.repo, else the target repo's origin.
ts_gh_resolve_repo() {
  [[ -n "$TS_GITHUB_REPO" ]] && return 0
  TS_GITHUB_REPO="$(cd "$1" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    && [[ -n "$TS_GITHUB_REPO" ]] \
    || { echo "error: can't resolve the GitHub repo from origin; set github.repo in docs/nightlight-meta.json" >&2; return 1; }
}

# Fetches open issues for each section label once, merges, drops blocked and
# needs-human, sorts by number. No-op if already cached this run.
ts_gh_fetch() {
  local repo_path="$1"
  [[ -n "$TS_GH_CACHE" && -f "$TS_GH_CACHE" ]] && return 0
  ts_gh_resolve_repo "$repo_path" || return 1
  local sections=("$(ts_gh_label agentReady nl:agent-ready)" "$(ts_gh_label verify nl:verify)" "$(ts_gh_label research nl:research)")
  local blocked needs_human stack_prefix
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
  jq -s --arg b "$blocked" --arg n "$needs_human" --arg p "$stack_prefix" '
    add
    | unique_by(.number)
    | map(select(([.labels[].name] | index($b) | not) and ([.labels[].name] | index($n) | not)))
    | map(. + {stack: ([.labels[].name | select(startswith($p)) | ltrimstr($p)] | first // null)})
    | sort_by(.number)
  ' "$raw" > "$TS_GH_CACHE" || { rm -f "$raw" "$TS_GH_CACHE"; TS_GH_CACHE=""; return 1; }
  rm -f "$raw"
}

# Any open dispatchable work? Prints nothing; exit status is the answer. Also
# primes the cache ts_list_tasks reads.
ts_is_eligible() {
  ts_gh_fetch "$1" || return 1
  jq -e 'length > 0' "$TS_GH_CACHE" >/dev/null
}

# Writes one synthesized block file per issue under $2 (clearing anything
# already there) and prints "<number>\t<effective-stack>\t<blockfile>"
# lines in issue-number order. Effective stack is the nl:stack:* label, else the
# previous task's stack (solo if none yet). Only OWNER/MEMBER/COLLABORATOR
# comments make it into the block; the issue body is included as-is since the
# section label (which needs triage access to apply) is the gate.
ts_list_tasks() {
  local repo_path="$1" outdir="$2"
  mkdir -p "$outdir"
  rm -f "$outdir"/*.task
  ts_gh_fetch "$repo_path" || return 1

  local idx=0 prev_stack="" num stack file
  while IFS=$'\t' read -r num stack; do
    num="${num%$'\r'}"; stack="${stack%$'\r'}"
    [[ "$stack" == "null" || -z "$stack" ]] && stack="${prev_stack:-solo}"
    prev_stack="$stack"
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
  done < <(jq -r '.[] | "\(.number)\t\(.stack // "")"' "$TS_GH_CACHE")
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
