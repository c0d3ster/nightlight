#!/usr/bin/env bash
# usage: bash lib/ensure-labels.sh <repo-path> [extra-label]...
#
# Creates the nl:* labels a GitHub-source repo lacks (see ts_gh_ensure_labels in
# lib/task-source-github.sh). Safe to repeat. Works before taskSource is flipped
# to github (migrate, tidy): reads github.repo and labels from the meta file when
# present, else the repo's origin. Prints "created <name>" per label it made.

set -u
repo="${1:?usage: ensure-labels.sh <repo-path> [extra-label]...}"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/task-source-github.sh"

meta="$repo/docs/nightlight-meta.json"
TS_GITHUB_REPO="" TS_LABELS_JSON="{}"
if [[ -f "$meta" ]]; then
  jq -e . "$meta" >/dev/null 2>&1 || { echo "error: $meta is not valid JSON" >&2; exit 1; }
  TS_GITHUB_REPO="$(jq -r '.github.repo // empty' "$meta")"
  TS_LABELS_JSON="$(jq -c '.labels // {}' "$meta")"
fi
ts_gh_ensure_labels "$repo" "$@"
