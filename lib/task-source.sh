#!/usr/bin/env bash
# Shared task-source loader, sourced by overnight.sh and plan.sh (cwd must be the nightlight checkout).
source lib/env.sh

# Reads taskSource and its config blocks from $1 (repo path)'s
# docs/nightlight-meta.json, then sources lib/task-source-<name>.sh. Missing
# file or field means local. Sets TASK_SOURCE, TS_GITHUB_REPO, TS_LINEAR_TEAM_ID
# TS_LINEAR_STATUSES_JSON (linear.statuses, "{}" if absent) and TS_LABELS_JSON (the raw optional labels object, "{}" if absent) for the
# modules to read. Only the chosen source's block is read.
# github.repo is optional (the github module falls back to origin).
#
# ts_is_eligible <repo> exits 0 (eligible), 1 (nothing to do, quiet skip) or 2
# (lookup failed: error on stderr naming the repo; callers must not report it
# as "no open tasks").
#
# Optional grouping contract (every module defines both, so callers need no
# `declare -F` guard): ts_ensure_group <repo> <stack> <description> makes sure
# a tracker group for the stack exists and is open; ts_close_group <repo>
# <stack> closes it. Both skip `solo`, are idempotent, and warn instead of
# failing, since the nl:stack label stays authoritative. GitHub maps a stack to
# a milestone; local and linear are no-op stubs (Linear milestones are
# managed through the MCP tools in the prompts, see CLAUDE.md).
#
# Remote modules (github, linear) also define the PR-less housekeeping hooks:
# ts_stack_notes_export <repo> <dir> [stack] writes <dir>/<stack>.md (entries)
# and <stack>.ref (the tracker object) from the tracker; ts_stack_notes_write_instructions
# <stack> <ref> is the prompt text telling a task session how to write its entry;
# ts_stats_counts <repo> prints "<overnight> <manual> <blocked>" for stats.sh.
# Local keeps file-based notes and meta counters and defines none of them.
load_task_source() {
  local repo_path="$1" meta="$1/docs/nightlight-meta.json"
  TASK_SOURCE=local TS_GITHUB_REPO="" TS_LINEAR_TEAM_ID="" TS_LINEAR_STATUSES_JSON="{}" TS_LABELS_JSON="{}"
  # The model every claude -p session for this repo runs on: the meta's
  # "model", else NIGHTLIGHT_MODEL from nightlight's .env (your plan is about
  # you, not the repo), else sonnet to keep runs cheap. An alias (opus,
  # sonnet, haiku) follows the newest release of that family.
  NL_MODEL="${NIGHTLIGHT_MODEL:-sonnet}"
  if [[ -f "$meta" ]]; then
    jq -e . "$meta" >/dev/null 2>&1 || { echo "error: $meta is not valid JSON"; return 1; }
    TASK_SOURCE="$(jq -r '.taskSource // "local"' "$meta")"
    TS_LABELS_JSON="$(jq -c '.labels // {}' "$meta")"
    jq -e '(.model // "x") | type == "string" and length > 0' "$meta" >/dev/null \
      || { echo "error: model in $meta must be a non-empty string (an alias like sonnet or opus, or a full model id)"; return 1; }
    NL_MODEL="$(jq -r --arg d "$NL_MODEL" '.model // $d' "$meta")"
  fi
  case "$TASK_SOURCE" in
    local) ;;
    github)
      TS_GITHUB_REPO="$(jq -r '.github.repo // empty' "$meta")"
      ;;
    linear)
      TS_LINEAR_TEAM_ID="$(jq -r '.linear.teamId // empty' "$meta")"
      TS_LINEAR_STATUSES_JSON="$(jq -c '.linear.statuses // {}' "$meta")"
      [[ -n "$TS_LINEAR_TEAM_ID" ]] || { echo "error: taskSource is \"linear\" but linear.teamId is missing in $meta"; return 1; }
      LINEAR_API_KEY="$(env_get LINEAR_API_KEY "$repo_path" .)" || { echo "error: LINEAR_API_KEY not found in $repo_path env files or nightlight's own"; return 1; }
      export LINEAR_API_KEY
      ;;
    *) echo "error: unknown taskSource \"$TASK_SOURCE\" in $meta (expected local, github, or linear)"; return 1 ;;
  esac
  local module="lib/task-source-$TASK_SOURCE.sh"
  [[ -f "$module" ]] || { echo "error: taskSource \"$TASK_SOURCE\" is not implemented yet ($module missing)"; return 1; }
  source "$module"
}
