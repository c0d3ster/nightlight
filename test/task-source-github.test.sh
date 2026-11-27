#!/usr/bin/env bash
# lib/task-source-github.sh against REST-shaped fixtures.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/task-source.sh"
source "$NL/lib/task-source-github.sh"
R=acme/app
iss() { route "GET repos/$R/issues?state=$1&per_page=100&labels=$(gh_uri "$2")" "${@:3}"; }
empty() { echo '[]' > "$TMP/empty.json"; echo "$TMP/empty.json"; }
# issue <number> <comments> <label>...: one REST issue object.
issue() { local n="$1" c="$2"; shift 2; jq -cn --argjson n "$n" --argjson c "$c" --args '{number: $n, title: "Task \($n)", body: "Body \($n)", state: "open", comments: $c, labels: [$ARGS.positional[] | {name: .}]}' "$@"; }
setup() { TS_GITHUB_REPO=$R TS_LABELS_JSON='{}' TS_GH_CACHE=""; }

sections() {
  printf '[%s,%s,%s,%s]' "$(issue 10 0 nl:agent-ready nl:stack:a)" "$(issue 11 2 nl:agent-ready)" \
    "$(issue 14 0 nl:agent-ready nl:stack:c nl:blocked)" "$(issue 16 0 nl:agent-ready nl:stack:solo)" > "$TMP/ar.json"
  printf '[%s,%s]' "$(issue 12 0 nl:verify nl:stack:solo nl:priority:high)" "$(issue 15 0 nl:verify nl:needs-human)" > "$TMP/v.json"
  printf '[%s, {"number": 99, "pull_request": {}, "labels": [{"name": "nl:research"}]}]' "$(issue 13 0 nl:research nl:stack:b nl:priority:low)" > "$TMP/r.json"
  iss open nl:agent-ready "$TMP/ar.json"; iss open nl:verify "$TMP/v.json"; iss open nl:research "$TMP/r.json"
}

test_fetch_orders_and_filters() {
  setup; sections
  ts_gh_fetch /nowhere || fail "fetch failed"
  eq "$(jq -r '[.[] | "\(.number):\(.stack)"] | join(" ")' "$TS_GH_CACHE")" "12:solo 10:a 11:a 16:solo 13:b" \
    "priority groups, stack inheritance, blocked/needs-human and PRs dropped"
  ts_gh_fetch /nowhere; eq "$(ncalls 'issues?')" 3 "cached: one call per section label"
}
test_list_tasks_blocks_and_comments() {
  setup; sections
  jq '[.[0] + {author_association: "OWNER"}, .[1] + {author_association: "NONE", body: "drive-by"}]' "$GH_STUB_FIXTURES/fx-comments-323.json" > "$TMP/c.json"
  route "GET repos/$R/issues/11/comments?per_page=100" "$TMP/c.json"
  local out; out="$(ts_list_tasks /nowhere "$TMP/out")"
  eq "$(cut -f1,2 <<< "$out" | tr '\t\n' ': ')" "12:solo 10:a 11:a 16:solo 13:b "
  local f11; f11="$(sed -n 3p <<< "$out" | cut -f3)"
  has "$(cat "$f11")" "- [ ] #11 [stack: a] Task 11"
  has "$(cat "$f11")" "### Comment by someone"
  lacks "$(cat "$f11")" "drive-by" "non-member comment dropped"
  eq "$(ncalls '/comments')" 1 "comments fetched only for the issue that has any"
}
test_list_tasks_comment_failure() {
  setup; sections; route "GET repos/$R/issues/11/comments?per_page=100" '!1 HTTP 502'
  ts_list_tasks /nowhere "$TMP/out" >/dev/null 2>&1 && fail "should fail"
  return 0
}
test_is_eligible() {
  setup; sections; ts_is_eligible /nowhere; eq "$?" 0 "tasks"
  : > "$GH_STUB_DIR/routes"; setup; local e; e="$(empty)"
  iss open nl:agent-ready "$e"; iss open nl:verify "$e"; iss open nl:research "$e"; iss open nl:discovered "$e"
  ts_is_eligible /nowhere; eq "$?" 1 "nothing"
  : > "$GH_STUB_DIR/routes"; setup
  iss open nl:agent-ready "$e"; iss open nl:verify "$e"; iss open nl:research "$e"; iss open nl:discovered fx-issues-stack-notes.json
  ts_is_eligible /nowhere; eq "$?" 0 "discovered only"
  : > "$GH_STUB_DIR/routes"; setup; iss open nl:agent-ready '!1 gh: Bad credentials (HTTP 401)'
  ts_is_eligible /nowhere 2>/dev/null; eq "$?" 2 "lookup failed"
}
test_discovered_count() {
  setup; jq '[.[] | select(.pull_request | not)]' "$GH_STUB_FIXTURES/fx-issues-open.json" > "$TMP/d.json"
  iss open nl:discovered "$TMP/d.json"
  eq "$(ts_discovered_count /nowhere)" "$(jq length "$TMP/d.json")"
  : > "$GH_STUB_DIR/routes"; iss open nl:discovered '!1 gh: Bad credentials (HTTP 401)'
  local out err; out="$(ts_discovered_count /nowhere 2>"$TMP/e")"; eq "$?" 1 "fails"; eq "$out" 0 "prints 0"
  has "$(cat "$TMP/e")" "authentication failed"
}
test_find_related() {
  setup
  route "GET search/issues?q=$(gh_uri "Migrated from TASKS.md #5 ( x repo:$R is:issue")&per_page=30" fx-search.json
  local out; out="$(ts_find_related /nowhere '"Migrated" from TASKS.md #5 ( -x:')"
  eq "$(head -n1 <<< "$out")" "$(jq -r '.items[0] | "\(.state)\t#\(.number)\t\(.title)"' "$GH_STUB_FIXTURES/fx-search.json")"
  eq "$(wc -l <<< "$out")" "$(jq '.items | length' "$GH_STUB_FIXTURES/fx-search.json")"
  eq "$(ts_find_related /nowhere '"" : -')" "" "empty after defusing: no call"; eq "$(ncalls search)" 1
}
test_ensure_labels() {
  setup; route "GET repos/$R/labels?per_page=100" fx-labels.json
  local out; out="$(ts_gh_ensure_labels /nowhere nl:stack:brand-new nl:agent-ready)"
  eq "$out" "created nl:stack:brand-new" "only the missing label"
  has "$(calls)" "-X POST repos/$R/labels -f name=nl:stack:brand-new -f color="
  : > "$GH_STUB_DIR/calls"
  route "POST repos/$R/labels" '!1 gh: Validation Failed (HTTP 422)|{"errors":[{"code":"already_exists"}]}'
  out="$(ts_gh_ensure_labels /nowhere other-new 2>"$TMP/e")"; eq "$?" 0 "already exists is fine"; eq "$out" ""
  : > "$GH_STUB_DIR/routes"; route "GET repos/$R/labels?per_page=100" fx-labels.json
  route "POST repos/$R/labels" '!1 gh: Resource not accessible by integration (HTTP 403)'
  ts_gh_ensure_labels /nowhere x-new 2>"$TMP/e" >/dev/null; eq "$?" 1 "other errors fail"
  has "$(cat "$TMP/e")" "creating label x-new failed"
  : > "$GH_STUB_DIR/calls"
  out="$(DRY_RUN=1 ts_gh_ensure_labels /nowhere y-new 2>"$TMP/e")"
  eq "$(ncalls POST)" 0 "dry run writes nothing"; has "$(cat "$TMP/e")" "DRY_RUN: gh api -X POST repos/$R/labels -f name=y-new"
}
test_milestones() {
  setup; route "GET repos/$R/milestones?state=all&per_page=100" fx-milestones.json
  local open closed
  open="$(jq -r 'map(select(.state == "open")) | first.title' "$GH_STUB_FIXTURES/fx-milestones.json")"
  closed="$(jq -r 'map(select(.state == "closed")) | first | "\(.number) \(.title)"' "$GH_STUB_FIXTURES/fx-milestones.json")"
  ts_ensure_group /nowhere "$open"; eq "$(ncalls '-X ')" 0 "open milestone: no write"
  ts_ensure_group /nowhere "${closed#* }"; has "$(calls)" "-X PATCH repos/$R/milestones/${closed%% *} -f state=open"
  ts_ensure_group /nowhere brand-new "the desc"; has "$(calls)" "-X POST repos/$R/milestones -f title=brand-new -f description=the desc"
  ts_ensure_group /nowhere solo; ts_close_group /nowhere solo
  ts_close_group /nowhere "$open"; has "$(calls)" "state=closed"
  eq "$(ncalls '-X ')" 3 "solo untouched"
  route "POST repos/$R/milestones" '!1 HTTP 403'
  ts_ensure_group /nowhere other-new 2>"$TMP/e"; eq "$?" 0 "failure warns"; has "$(cat "$TMP/e")" "warning: couldn't create milestone"
}
test_stack_notes_export() {
  setup; iss all nl:stack-notes fx-issues-stack-notes.json
  local n stack; n="$(jq '.[0].number' "$GH_STUB_FIXTURES/fx-issues-stack-notes.json")"
  stack="$(jq -r '.[0].title | sub("^[[]done[]] "; "") | sub("^stack-notes: "; "")' "$GH_STUB_FIXTURES/fx-issues-stack-notes.json")"
  route "GET repos/$R/issues/$n/comments?per_page=100" fx-comments-323.json
  ts_stack_notes_export /nowhere "$TMP/n" || fail "export failed"
  eq "$(cat "$TMP/n/$stack.md")" "$(jq -r 'map(.body) | join("\n\n")' "$GH_STUB_FIXTURES/fx-comments-323.json" | tr -d '\r')"
  eq "$(cat "$TMP/n/$stack.ref")" "issue #$n, currently titled \"$(jq -r '.[0].title' "$GH_STUB_FIXTURES/fx-issues-stack-notes.json")\""
  : > "$GH_STUB_DIR/calls"; ts_stack_notes_export /nowhere "$TMP/o" other-stack
  eq "$(ls "$TMP/o")" "" "other stack: nothing written"; eq "$(ncalls comments)" 0 "no comment call"
}
test_stack_notes_export_done_and_empty() {
  setup
  printf '[{"number": 7, "title": "[done] stack-notes: ui", "comments": 0, "labels": []}, {"number": 3, "title": "stack-notes: ui", "comments": 4, "labels": []}]' > "$TMP/s.json"
  iss all nl:stack-notes "$TMP/s.json"
  ts_stack_notes_export /nowhere "$TMP/n" ui
  eq "$(cat "$TMP/n/ui.ref")" 'issue #7, currently titled "[done] stack-notes: ui"' "newest issue wins, [done] prefix read"
  eq "$(cat "$TMP/n/ui.md")" "" "no comments"; eq "$(ncalls comments)" 0
  : > "$GH_STUB_DIR/routes"; iss all nl:stack-notes '!1 HTTP 500'
  ts_stack_notes_export /nowhere "$TMP/x" 2>/dev/null && fail "gh failure fails"
  return 0
}
test_write_instructions_are_rest() {
  setup
  local a b; a="$(ts_stack_notes_write_instructions ui "")"; b="$(ts_stack_notes_write_instructions ui 'issue #7, currently titled "x"')"
  has "$a" "gh api -X POST repos/$R/issues -f title='stack-notes: ui' -f 'labels[]=nl:stack-notes'"
  has "$b" "gh api -X POST repos/$R/issues/<number>/comments -F body=@<file>"
  has "$b" "gh api -X PATCH repos/$R/issues/<number> -f title='stack-notes: ui'"
  lacks "$a$b" "gh issue"
}
test_stats_counts() {
  setup
  printf '[%s,%s]' "$(issue 1 0 nl:agent-ready nl:overnight)" "$(issue 2 0 nl:agent-ready)" > "$TMP/ar.json"
  printf '[%s]' "$(issue 3 0 nl:verify)" > "$TMP/v.json"; printf '[%s]' "$(issue 1 0 nl:agent-ready nl:overnight)" > "$TMP/o.json"
  iss closed nl:agent-ready "$TMP/ar.json"; iss closed nl:verify "$TMP/v.json"; iss closed nl:research "$(empty)"
  iss closed nl:overnight "$TMP/o.json"; iss open nl:blocked fx-issues-stack-notes.json
  eq "$(ts_stats_counts /nowhere)" "1 2 1" "overnight, manual, blocked"
}
test_resolve_repo() {
  TS_GITHUB_REPO="" TS_LABELS_JSON='{}'
  local d="$TMP/r"; git init -q "$d"; git -C "$d" remote add origin git@github.com:acme/zed.git
  ts_gh_resolve_repo "$d"; eq "$TS_GITHUB_REPO" acme/zed
  TS_GITHUB_REPO=""; git init -q "$TMP/n"; ts_gh_resolve_repo "$TMP/n" 2>"$TMP/e" && fail "no origin"
  has "$(cat "$TMP/e")" "can't resolve the repo from origin"
}
test_explain() {
  TS_GITHUB_REPO=acme/app
  eq "$(ts_gh_explain x 'gh: Bad credentials (HTTP 401)' 2>&1)" "error: GitHub acme/app: x: authentication failed (run gh auth login or set GH_TOKEN): gh: Bad credentials (HTTP 401)"
  has "$(ts_gh_explain x 'dial tcp: i/o timeout' 2>&1)" "network error"
  has "$(ts_gh_explain x 'gh: Not Found (HTTP 404)' 2>&1)" "repo not found or no access"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
