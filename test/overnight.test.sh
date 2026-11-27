#!/usr/bin/env bash
# overnight.sh's PR lookups and prompt text. overnight.sh runs on load, so its
# functions are pulled out by name.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/task-source.sh"
source "$NL/lib/task-source-github.sh"
for fn in task_branch_token find_orphan_branches load_task_prs find_task_pr resolve_base_branch stack_branch_is_live \
  gh_prompt_prs gh_prompt_pr_create build_task_prompt build_housekeeping_prompt \
  build_housekeeping_prompt_github build_housekeeping_prompt_linear; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$NL/overnight.sh")"
  declare -F "$fn" >/dev/null || { echo "can't load $fn from overnight.sh"; exit 1; }
done
GH_REPO_SLUG=acme/app
pulls() { route "GET repos/acme/app/pulls?state=all&per_page=100" "$@"; }
branch_prs() { route "GET repos/acme/app/pulls?state=all&head=$(gh_uri "acme:$1")&per_page=100" "$2"; }
P='overnight/2026-11-01/r1-01'

test_find_task_pr() {
  TASK_PR_CACHE="" TS_NUMERIC_IDS=1
  jq -n --arg p "$P" '[
    {number: 1, state: "closed", merged_at: null, head: {ref: "\($p)-i5-a"}},
    {number: 2, state: "closed", merged_at: "2026-11-02T00:00:00Z", head: {ref: "\($p)-i5-b"}},
    {number: 3, state: "open", merged_at: null, head: {ref: "\($p)-t7-c"}},
    {number: 4, state: "closed", merged_at: "2026-11-02T00:00:00Z", head: {ref: "\($p)-t8-d"}},
    {number: 5, state: "closed", merged_at: null, head: {ref: "\($p)-iENG-9-e"}}]' > "$TMP/p.json"
  pulls "$TMP/p.json"
  load_task_prs || fail "prime"
  eq "$(find_task_pr x 5)" "merged #2" "merged beats closed"
  eq "$(find_task_pr x 7)" "open #3" "open legacy -t PR counts"
  eq "$(find_task_pr x 8)" "" "merged legacy -t PR ignored for numeric ids"
  eq "$(find_task_pr x 6)" "" "no PR"
  TS_NUMERIC_IDS=0
  eq "$(find_task_pr x 8)" "merged #4" "opaque ids count legacy PRs in any state"
  eq "$(find_task_pr x eng-9)" "closed #5" "case-insensitive"
  eq "$(ncalls pulls)" 1 "listed once, cached across \$(...) calls"
}
test_find_task_pr_failure() {
  TASK_PR_CACHE="" TS_NUMERIC_IDS=1; pulls '!1 HTTP 401'
  find_task_pr x 5; eq "$?" 1 "gh failure"; eq "$TASK_PR_CACHE" "" "nothing cached"
}
test_find_task_pr_real_pages() {
  TASK_PR_CACHE="" TS_NUMERIC_IDS=1
  jq '.[0:50]' "$GH_STUB_FIXTURES/nl-pulls-all.json" > "$TMP/a.json"; jq '.[50:]' "$GH_STUB_FIXTURES/nl-pulls-all.json" > "$TMP/b.json"
  pulls "$TMP/a.json" "$TMP/b.json"
  local id n; read -r id n < <(jq -r '[.[] | select(.head.ref | test("^overnight/.*-t[0-9]+-")) | select(.merged_at)] | last | "\(.head.ref | capture("-t(?<n>[0-9]+)-").n) \(.number)"' "$GH_STUB_FIXTURES/nl-pulls-all.json")
  TS_NUMERIC_IDS=0; eq "$(find_task_pr x "$id")" "merged #$n" "a merged task PR on the second page"
}
test_orphans_and_live() {
  local c; c="$(make_repo acme/app)"; TASK_SOURCE=local
  git -C "$c" branch -q "$P-t4-orphan"; git -C "$c" branch -q "$P-t4-haspr"; git -C "$c" branch -q "$P-t5-other"
  echo '[]' > "$TMP/none.json"; echo '[{"number": 9, "state": "open", "merged_at": null}]' > "$TMP/one.json"
  branch_prs "$P-t4-orphan" "$TMP/none.json"; branch_prs "$P-t4-haspr" "$TMP/one.json"
  eq "$(find_orphan_branches "$c" 4)" "$P-t4-orphan"
  stack_branch_is_live "$c" "$P-t4-orphan" || fail "existing branch is live"
  branch_prs gone "$TMP/none.json"; stack_branch_is_live "$c" gone && fail "no branch, no PR is not live"
  branch_prs merged-gone "$TMP/one.json"; stack_branch_is_live "$c" merged-gone || fail "a PR keeps it live"
  stack_branch_is_live "$c" unknown || fail "gh failure counts as live"
}
test_resolve_base_branch() {
  local c; c="$(make_repo acme/app)"; local -A map=()
  git -C "$c" branch -q prior; git -C "$c" push -q origin prior
  eq "$(resolve_base_branch "$c" solo main map)" main
  echo '[{"number": 2, "state": "open", "merged_at": null}]' > "$TMP/o.json"; branch_prs prior "$TMP/o.json"
  eq "$(resolve_base_branch "$c" s main map $'## x\nBranch: prior')" prior "unmerged: chain"
  : > "$GH_STUB_DIR/routes"
  echo '[{"number": 2, "state": "closed", "merged_at": "2026-11-02T00:00:00Z"}]' > "$TMP/m.json"; branch_prs prior "$TMP/m.json"
  eq "$(resolve_base_branch "$c" s main map $'## x\nBranch: prior' 2>"$TMP/e")" main "merged: re-root"
  has "$(cat "$TMP/e")" "already merged into main"
  map[s]=same-run; eq "$(resolve_base_branch "$c" s main map)" same-run
}

no_graphql() { [[ ! "$1" =~ gh\ (issue|pr|label|repo)\ (view|list|create|edit|close|comment|merge) ]] || fail "GraphQL gh command in prompt: ${BASH_REMATCH[0]}"; }
test_task_prompt_github() {
  TASK_SOURCE=github TS_GITHUB_REPO=acme/tracker TS_LABELS_JSON='{}' EXTRA_INSTRUCTIONS="" TS_NUMERIC_IDS=1
  local p; p="$(build_task_prompt "- [ ] #5 x" 5 solo main "" 01 1)"
  has "$p" "gh api -X POST repos/acme/app/pulls -f head=<branch> -f base=main"
  has "$p" "gh api repos/acme/tracker/issues/5 --jq"
  has "$p" "gh api 'repos/acme/app/pulls?state=all&head=acme:<branch>'"
  no_graphql "$p"
  p="$(build_task_prompt "- [ ] #6 y" 6 ui overnight/prev "## e" 02 1 "" 'issue #7, currently titled "stack-notes: ui"')"
  has "$p" "-f base=overnight/prev"; has "$p" "repos/acme/tracker/issues/<number>/comments"; no_graphql "$p"
}
test_housekeeping_prompts() {
  TS_GITHUB_REPO=acme/tracker TS_LABELS_JSON='{}' TS_LINEAR_TEAM_ID=ENG TS_LINEAR_STATUSES_JSON='{}'
  local p
  TASK_SOURCE=local; p="$(build_housekeeping_prompt "TASK_RESULT: #1" "" 2 " --keep a")"
  has "$p" "-f head=overnight/<YYYY-MM-DD>/r2-housekeeping -f base=main"; has "$p" "repos/acme/app/pulls/<number>"; no_graphql "$p"
  TASK_SOURCE=github; p="$(build_housekeeping_prompt "" "" 2 "" /tmp/n)"
  has "$p" "gh api -X PATCH repos/acme/tracker/issues/<n> -f state=closed -f state_reason=completed -f 'labels[]=<kept label>' -f 'labels[]=nl:overnight'"
  has "$p" "repos/acme/tracker/issues?state=all&labels=nl:stack-notes"; has "$p" "repos/acme/tracker/milestones/<number> -f state=closed"
  lacks "$p" "--repo"; no_graphql "$p"
  source "$NL/lib/task-source-linear.sh"
  TASK_SOURCE=linear; p="$(build_housekeeping_prompt "" "" 2 "" /tmp/n)"
  has "$p" "gh api --paginate 'repos/acme/app/pulls?state=all&per_page=100'"; no_graphql "$p"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
