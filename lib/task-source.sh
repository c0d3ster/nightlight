#!/usr/bin/env bash
# Shared task-source loader, sourced by overnight.sh and plan.sh (cwd must be the nightlight checkout).

# Reads taskSource and its config blocks from $1 (repo path)'s
# docs/nightlight-meta.json, then sources lib/task-source-<name>.sh. Missing
# file or field means local. Sets TASK_SOURCE, TS_GITHUB_REPO, TS_LINEAR_TEAM_ID
# and TS_LABELS_JSON (the raw optional labels object, "{}" if absent) for the
# modules to read. Only the chosen source's block is read.
# github.repo is optional (the github module falls back to origin).
load_task_source() {
  local repo_path="$1" meta="$1/docs/nightlight-meta.json"
  TASK_SOURCE=local TS_GITHUB_REPO="" TS_LINEAR_TEAM_ID="" TS_LABELS_JSON="{}"
  if [[ -f "$meta" ]]; then
    jq -e . "$meta" >/dev/null 2>&1 || { echo "error: $meta is not valid JSON"; return 1; }
    TASK_SOURCE="$(jq -r '.taskSource // "local"' "$meta")"
    TS_LABELS_JSON="$(jq -c '.labels // {}' "$meta")"
  fi
  case "$TASK_SOURCE" in
    local) ;;
    github)
      TS_GITHUB_REPO="$(jq -r '.github.repo // empty' "$meta")"
      ;;
    linear)
      TS_LINEAR_TEAM_ID="$(jq -r '.linear.teamId // empty' "$meta")"
      [[ -n "$TS_LINEAR_TEAM_ID" ]] || { echo "error: taskSource is \"linear\" but linear.teamId is missing in $meta"; return 1; }
      ;;
    *) echo "error: unknown taskSource \"$TASK_SOURCE\" in $meta (expected local, github, or linear)"; return 1 ;;
  esac
  local module="lib/task-source-$TASK_SOURCE.sh"
  [[ -f "$module" ]] || { echo "error: taskSource \"$TASK_SOURCE\" is not implemented yet ($module missing)"; return 1; }
  source "$module"
}
