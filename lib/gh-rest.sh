#!/usr/bin/env bash
# REST wrappers for the gh calls nightlight makes. `gh issue`, `gh pr`, `gh label`
# and `gh repo view` go through GraphQL, which Claude Code cloud sessions block;
# `gh api` REST works there and locally alike.
#
# Source it for the ghr_* functions, or run one as a command:
#   bash lib/gh-rest.sh <command> <args>    (command = function name minus ghr_, _ as -)
# e.g. bash lib/gh-rest.sh issue-list c0d3ster/app --state open --label nl:discovered
#
# Output keeps gh's --json shape so callers barely change: camelCase fields,
# upper-case states (OPEN, CLOSED, MERGED), labels as [{name}], author as {login},
# body "" rather than null. Lists are one JSON array, fetched with --paginate.
# Writes print what gh would (the new object's URL). DRY_RUN=1 makes every write
# print the exact gh/git command on stderr instead of running it; reads still run.

# Issue and PR objects in gh --json shape.
GHR_ISSUE_JQ='{number, title, body: (.body // ""), state: (.state | ascii_upcase),
  labels: [.labels[] | {name}], author: {login: .user.login}, createdAt: .created_at,
  updatedAt: .updated_at, closedAt: .closed_at, url: .html_url,
  milestone: (if .milestone then {number: .milestone.number, title: .milestone.title} else null end)}'
GHR_PR_JQ='{number, title, body: (.body // ""),
  state: (if .merged_at then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end),
  headRefName: .head.ref, baseRefName: .base.ref, mergedAt: .merged_at, createdAt: .created_at, url: .html_url}'

# Runs a write: gh api -X <method> <path>, JSON payload $3 on stdin. Refuses a
# payload that is not a JSON object (a failed jq upstream), so a broken call
# never sends a partial write.
_ghr_write() {
  local method="$1" path="$2" payload="${3:-}"
  if [[ $# -ge 3 ]] && ! jq -e 'type == "object"' <<< "$payload" >/dev/null 2>&1; then
    echo "error: refusing $method $path: payload is not a JSON object" >&2
    return 1
  fi
  if [[ "${DRY_RUN:-}" == 1 ]]; then
    echo "DRY_RUN: gh api -X $method $path${payload:+ --input - <<< '$payload'}" >&2
    echo '{"html_url":"(dry-run)"}'
    return 0
  fi
  if [[ -n "$payload" ]]; then
    gh api -X "$method" "$path" --input - <<< "$payload"
  else
    gh api -X "$method" "$path"
  fi
}

# _ghr_paged <jq-filter> <gh api args>...: every page through the filter, slurped
# into one JSON array. Fails when gh does (a pipe into jq -s would hide that).
_ghr_paged() {
  local filter="$1" out; shift
  out="$(gh api "$@" --paginate --jq "$filter")" || return 1
  jq -s . <<< "$out"
}

# _ghr_write, then prints the html_url of the object it made or changed.
_ghr_write_url() {
  local out
  out="$(_ghr_write "$@")" || return 1
  jq -r .html_url <<< "$out"
}

# Prints the text of a --body/--body-file pair ("-" reads stdin).
_ghr_body() {
  if [[ "$1" != --body-file ]]; then printf '%s' "$2"
  elif [[ "$2" == - ]]; then cat
  else cat -- "$2"
  fi
}

# Splits gh-style label args ("a,b" or repeated flags) into one name per line.
_ghr_split() { tr ',' '\n' <<< "$1" | sed '/^$/d'; }

# owner/name of the checkout at $1, from its origin URL (https, ssh, scp-style or
# a proxy URL ending in /<owner>/<repo>), canonicalised through the REST API the
# way `gh repo view --json nameWithOwner` reports it.
ghr_repo() {
  local url slug
  url="$(git -C "${1:-.}" remote get-url origin 2>&1)" || { echo "error: no origin remote in ${1:-.}: $url" >&2; return 1; }
  slug="$(sed -E 's#\.git/?$##; s#/+$##; s#^[^@/]+@([^:/]+):#\1/#' <<< "$url" | awk -F/ 'NF >= 2 {print $(NF-1) "/" $NF}')"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "error: can't read owner/repo from origin URL $url" >&2; return 1; }
  gh api "repos/$slug" --jq .full_name
}

# ghr_issue_list <repo> [--state open|closed|all] [--label <name>] [--comments]
# Like gh issue list --json number,title,body,state,labels,author,createdAt,...
# (no pull requests). --comments adds comments: [{author: {login},
# authorAssociation, body, createdAt}], one extra call per issue.
ghr_issue_list() {
  local repo="$1"; shift
  local state=open label="" comments=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --comments) comments=1; shift ;;
      *) echo "error: ghr_issue_list: unknown argument $1" >&2; return 2 ;;
    esac
  done
  local args=(-X GET "repos/$repo/issues" -f state="$state" -f per_page=100)
  [[ -n "$label" ]] && args+=(-f labels="$label")
  local out
  out="$(_ghr_paged ".[] | select(.pull_request | not) | $GHR_ISSUE_JQ" "${args[@]}")" || return 1
  [[ "$comments" == 1 ]] || { printf '%s\n' "$out"; return 0; }
  local num cs all="[]"
  while IFS= read -r num; do
    cs="$(_ghr_paged '.[] | {author: {login: .user.login}, authorAssociation: .author_association, body: (.body // ""), createdAt: .created_at}' \
      "repos/$repo/issues/$num/comments?per_page=100")" || return 1
    all="$(jq -c --argjson n "$num" --argjson c "$cs" '. + [{number: $n, comments: $c}]' <<< "$all")"
  done < <(jq -r '.[].number' <<< "$out")
  jq --argjson c "$all" '($c | map({key: (.number | tostring), value: .comments}) | from_entries) as $m
    | map(. + {comments: $m[.number | tostring]})' <<< "$out"
}

# ghr_issue_search <repo> <query> [--state open|closed|all] [--limit n]
# Like gh issue list --search <query> --json number,title,state (issues only).
ghr_issue_search() {
  local repo="$1" query="$2"; shift 2
  local state=all limit=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) echo "error: ghr_issue_search: unknown argument $1" >&2; return 2 ;;
    esac
  done
  local q="$query repo:$repo is:issue"
  [[ "$state" != all ]] && q="$q is:$state"
  gh api -X GET search/issues -f q="$q" -f per_page="$limit" \
    --jq "[.items[] | {number, title, state: (.state | ascii_upcase), url: .html_url}]"
}

# Milestone number for title $2 (any state); fails if there is none.
ghr_milestone_number() {
  local out
  out="$(gh api "repos/$1/milestones?state=all&per_page=100" --paginate --jq ".[] | select(.title == $(jq -Rn --arg t "$2" '$t')) | .number")" || return 1
  out="${out%%$'\n'*}"
  [[ "$out" =~ ^[0-9]+$ ]] || { echo "error: no milestone titled \"$2\" in $1" >&2; return 1; }
  printf '%s\n' "$out"
}

# ghr_issue_create <repo> --title <t> [--body <b> | --body-file <f>] [--label <a,b>]... [--milestone <title>]
# Prints the new issue's URL, like gh issue create.
ghr_issue_create() {
  local repo="$1"; shift
  local title="" body="" labels="" milestone=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body|--body-file) body="$(_ghr_body "$1" "$2")" || return 1; shift 2 ;;
      --label) labels="$labels$(_ghr_split "$2")"$'\n'; shift 2 ;;
      --milestone) milestone="$2"; shift 2 ;;
      *) echo "error: ghr_issue_create: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$title" ]] || { echo "error: ghr_issue_create: --title is required" >&2; return 2; }
  local ms=null
  [[ -n "$milestone" ]] && { ms="$(ghr_milestone_number "$repo" "$milestone")" || return 1; }
  local payload
  payload="$(jq -cn --arg t "$title" --arg b "$body" --arg l "$labels" --argjson m "$ms" \
    '{title: $t, body: $b} + (($l | split("\n") | map(select(. != ""))) as $ls | if $ls == [] then {} else {labels: $ls} end)
     + (if $m then {milestone: $m} else {} end)')"
  _ghr_write_url POST "repos/$repo/issues" "$payload"
}

# ghr_issue_edit <repo> <n> [--title t] [--body b | --body-file f] [--add-label a,b]... [--remove-label a,b]... [--milestone <title>]
# One PATCH; label changes are applied to the issue's current set. Prints the URL.
ghr_issue_edit() {
  local repo="$1" num="$2"; shift 2
  local fields='{}' add="" remove="" body milestone
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) fields="$(jq -c --arg v "$2" '. + {title: $v}' <<< "$fields")"; shift 2 ;;
      --body|--body-file) body="$(_ghr_body "$1" "$2")" || return 1; fields="$(jq -c --arg v "$body" '. + {body: $v}' <<< "$fields")"; shift 2 ;;
      --add-label) add="$add$(_ghr_split "$2")"$'\n'; shift 2 ;;
      --remove-label) remove="$remove$(_ghr_split "$2")"$'\n'; shift 2 ;;
      --milestone) milestone="$(ghr_milestone_number "$repo" "$2")" || return 1
        fields="$(jq -c --argjson v "$milestone" '. + {milestone: $v}' <<< "$fields")"; shift 2 ;;
      *) echo "error: ghr_issue_edit: unknown argument $1" >&2; return 2 ;;
    esac
  done
  if [[ -n "$add$remove" ]]; then
    local cur
    cur="$(gh api "repos/$repo/issues/$num" --jq '[.labels[].name]')" || return 1
    fields="$(jq -c --argjson cur "$cur" --arg a "$add" --arg r "$remove" '
      ($a | split("\n") | map(select(. != ""))) as $add
      | ($r | split("\n") | map(select(. != ""))) as $rm
      | . + {labels: ((($cur + $add) | unique) - $rm)}' <<< "$fields")"
  fi
  [[ "$fields" != '{}' ]] || { echo "error: ghr_issue_edit: nothing to change" >&2; return 2; }
  _ghr_write_url PATCH "repos/$repo/issues/$num" "$fields"
}

# ghr_issue_comment <repo> <n> (--body b | --body-file f). Prints the comment URL.
ghr_issue_comment() {
  local repo="$1" num="$2" body; shift 2
  [[ $# -eq 2 ]] || { echo "error: ghr_issue_comment: needs --body or --body-file" >&2; return 2; }
  body="$(_ghr_body "$1" "$2")" || return 1
  _ghr_write_url POST "repos/$repo/issues/$num/comments" "$(jq -cn --arg b "$body" '{body: $b}')"
}

# ghr_issue_close <repo> <n> [--reason completed|"not planned"] [--comment <c>]
# Like gh issue close: the comment (if any) first, then the close.
ghr_issue_close() {
  local repo="$1" num="$2"; shift 2
  local reason=completed comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      --comment) comment="$2"; shift 2 ;;
      *) echo "error: ghr_issue_close: unknown argument $1" >&2; return 2 ;;
    esac
  done
  case "$reason" in
    completed) ;;
    "not planned"|not_planned) reason=not_planned ;;
    *) echo "error: ghr_issue_close: --reason is completed or \"not planned\"" >&2; return 2 ;;
  esac
  if [[ -n "$comment" ]]; then ghr_issue_comment "$repo" "$num" --body "$comment" >/dev/null || return 1; fi
  _ghr_write_url PATCH "repos/$repo/issues/$num" "$(jq -cn --arg r "$reason" '{state: "closed", state_reason: $r}')"
}

# Like gh label list --json name,color,description (every label).
ghr_label_list() {
  _ghr_paged '.[] | {name, color, description: (.description // "")}' "repos/$1/labels?per_page=100"
}

# ghr_label_create <repo> <name> [color] [description]. A random color when none
# is given, as gh label create does. An existing label fails with HTTP 422 and
# GitHub's error body (code "already_exists") on stderr.
ghr_label_create() {
  local repo="$1" name="$2" color="${3:-}" desc="${4:-}"
  [[ -n "$color" ]] || color="$(printf '%06x' $(( (RANDOM << 9 ^ RANDOM) & 0xffffff )))"
  local out
  out="$(_ghr_write POST "repos/$repo/labels" "$(jq -cn --arg n "$name" --arg c "${color#\#}" --arg d "$desc" '{name: $n, color: $c, description: $d}')")" \
    || { printf '%s\n' "$out" >&2; return 1; }
}

# ghr_pr_list <repo> [--state open|closed|merged|all] [--head <branch>] [--base <branch>]
# Like gh pr list --json number,title,body,state,headRefName,baseRefName,mergedAt,createdAt,url.
# --head is a branch of this repo (REST filters on <owner>:<branch>).
ghr_pr_list() {
  local repo="$1"; shift
  local state=open head="" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      *) echo "error: ghr_pr_list: unknown argument $1" >&2; return 2 ;;
    esac
  done
  local api_state="$state" filter=.
  [[ "$state" == merged ]] && { api_state=closed; filter='select(.merged_at)'; }
  local args=(-X GET "repos/$repo/pulls" -f state="$api_state" -f per_page=100)
  [[ -n "$head" ]] && args+=(-f head="${repo%%/*}:$head")
  [[ -n "$base" ]] && args+=(-f base="$base")
  _ghr_paged ".[] | $filter | $GHR_PR_JQ" "${args[@]}"
}

# ghr_pr_view <repo> <number | branch>: one PR object (shape as ghr_pr_list). For a
# branch, like gh pr view: its open PR, else its most recent one; fails if none.
ghr_pr_view() {
  local repo="$1" ref="$2"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    gh api "repos/$repo/pulls/$ref" --jq "$GHR_PR_JQ"
    return
  fi
  local list
  list="$(ghr_pr_list "$repo" --state all --head "$ref")" || return 1
  jq -e 'length > 0' <<< "$list" >/dev/null || { echo "no pull requests found for branch \"$ref\"" >&2; return 1; }
  jq '(map(select(.state == "OPEN")) | first) // (sort_by(.number) | last)' <<< "$list"
}

# ghr_pr_create <repo> --head <branch> --base <branch> --title <t> [--body b | --body-file f]
# Prints the new PR's URL, like gh pr create.
ghr_pr_create() {
  local repo="$1"; shift
  local head="" base="" title="" body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --head) head="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body|--body-file) body="$(_ghr_body "$1" "$2")" || return 1; shift 2 ;;
      *) echo "error: ghr_pr_create: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$head" && -n "$base" && -n "$title" ]] || { echo "error: ghr_pr_create: --head, --base and --title are required" >&2; return 2; }
  _ghr_write_url POST "repos/$repo/pulls" "$(jq -cn --arg h "$head" --arg b "$base" --arg t "$title" --arg d "$body" '{head: $h, base: $b, title: $t, body: $d}')"
}

# ghr_pr_merge <repo> <branch> [--delete-branch [<repo-path>]]
# Rebase-merges the branch's open PR, like gh pr merge <branch> --rebase. With
# --delete-branch, then deletes the branch on origin, best-effort (see
# ghr_delete_branch): a refused delete warns and still returns 0, since the
# merge itself succeeded.
ghr_pr_merge() {
  local repo="$1" branch="$2"; shift 2
  local delete=0 path=""
  if [[ "${1:-}" == --delete-branch ]]; then delete=1; path="${2:-}"; fi
  local num
  num="$(ghr_pr_list "$repo" --state open --head "$branch")" || return 1
  num="$(jq -r '.[0].number // empty' <<< "$num")"
  [[ -n "$num" ]] || { echo "error: no open pull request for branch \"$branch\" in $repo" >&2; return 1; }
  _ghr_write PUT "repos/$repo/pulls/$num/merge" '{"merge_method":"rebase"}' >/dev/null || return 1
  echo "merged #$num ($branch) with rebase"
  [[ "$delete" == 1 ]] && { ghr_delete_branch "$repo" "$branch" "$path" || true; }
  return 0
}

# ghr_delete_branch <repo> <branch> [<repo-path>]: deletes the branch on origin,
# best-effort. Tries git push --delete (from <repo-path> when given), then the
# REST ref delete. Cloud sessions refuse both, so a failure prints a warning
# naming the branch and returns 1; callers report it and carry on.
ghr_delete_branch() {
  local repo="$1" branch="$2" path="${3:-}" err
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "error: unsafe branch name '$branch'" >&2; return 2; }
  if [[ "${DRY_RUN:-}" == 1 ]]; then
    [[ -n "$path" ]] && echo "DRY_RUN: git -C $path push --quiet origin --delete $branch" >&2
    echo "DRY_RUN: gh api -X DELETE repos/$repo/git/refs/heads/$branch (if the push fails)" >&2
    return 0
  fi
  if [[ -n "$path" ]] && err="$(git -C "$path" push --quiet origin --delete "$branch" 2>&1)"; then return 0; fi
  if err="$err${err:+; }$(gh api -X DELETE "repos/$repo/git/refs/heads/$branch" 2>&1)"; then return 0; fi
  echo "warning: couldn't delete branch $branch on origin (refused here; delete it from GitHub or a local checkout): ${err//$'\n'/ }" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"; shift || true
  fn="ghr_${cmd//-/_}"
  if [[ -z "$cmd" ]] || ! declare -F "$fn" >/dev/null || [[ "$fn" == ghr__* ]]; then
    echo "usage: bash lib/gh-rest.sh <command> <args>; commands: $(declare -F | awk '$3 ~ /^ghr_[a-z]/ {sub(/^ghr_/, "", $3); gsub(/_/, "-", $3); printf "%s ", $3}')" >&2
    exit 2
  fi
  "$fn" "$@"
fi
