#!/usr/bin/env bash
# lib/github.sh: slug parsing, pagination, PR filtering, branch PR pick, writes.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/github.sh"

slug_of() { local d="$TMP/s$RANDOM"; git init -q "$d"; git -C "$d" remote add origin "$1"; gh_slug "$d"; }

test_slug_forms() {
  eq "$(slug_of https://github.com/c0d3ster/Fractaleyez.git)" c0d3ster/Fractaleyez https
  eq "$(slug_of https://github.com/c0d3ster/nightlight)" c0d3ster/nightlight "https, no .git"
  eq "$(slug_of git@github.com:acme/my.app.git)" acme/my.app scp-style
  eq "$(slug_of ssh://git@github.com/acme/app.git)" acme/app ssh
  eq "$(slug_of http://local_proxy@127.0.0.1:41234/git/acme/app)" acme/app "cloud proxy URL"
  eq "$(calls)" "" "no API call"
}
test_slug_failures() {
  local d="$TMP/none"; git init -q "$d"
  gh_slug "$d" 2>/dev/null && fail "no origin should fail"
  slug_of "not a url" 2>/dev/null && fail "unparsable origin should fail"
  return 0
}
test_cli_slug() {
  local d="$TMP/c"; git init -q "$d"; git -C "$d" remote add origin https://github.com/acme/app.git
  eq "$(bash "$NL/lib/github.sh" slug "$d")" acme/app
  bash "$NL/lib/github.sh" nope 2>/dev/null; eq "$?" 2 "unknown command exits 2"
}
test_uri() { eq "$(gh_uri 'nl:agent-ready')" 'nl%3Aagent-ready'; eq "$(gh_uri 'a b,c/d')" 'a%20b%2Cc%2Fd'; }

test_paged_concatenates_pages() {
  jq '.[0:60]' "$GH_STUB_FIXTURES/nl-pulls-all.json" > "$TMP/p1.json"
  jq '.[60:]' "$GH_STUB_FIXTURES/nl-pulls-all.json" > "$TMP/p2.json"
  route "GET repos/acme/app/pulls?state=all&per_page=100" "$TMP/p1.json" "$TMP/p2.json"
  local out; out="$(gh_paged "repos/acme/app/pulls?state=all&per_page=100" '{number}')"
  eq "$(jq length <<< "$out")" 100 "both pages"
  eq "$(jq -c '[.[0].number, .[99].number]' <<< "$out")" "$(jq -c '[.[0].number, .[99].number]' "$GH_STUB_FIXTURES/nl-pulls-all.json")"
  has "$(calls)" "--paginate"
}
test_paged_empty() { echo '[]' > "$TMP/e.json"; route "GET x" "$TMP/e.json"; eq "$(gh_paged x)" "[]"; }
test_paged_failure() {
  route "GET repos/acme/app/issues?state=open&per_page=100" '!1 gh: Bad credentials (HTTP 401)'
  gh_paged "repos/acme/app/issues?state=open&per_page=100" >/dev/null 2>&1 && fail "should fail"
  return 0
}

test_issues_drops_prs() {
  route "GET repos/acme/app/issues?state=open&per_page=100" fx-issues-open.json
  local out; out="$(gh_issues acme/app open)"
  eq "$(jq '[.[] | select(.pull_request)] | length' <<< "$out")" 0 "no PRs"
  eq "$(jq length <<< "$out")" "$(jq '[.[] | select(.pull_request | not)] | length' "$GH_STUB_FIXTURES/fx-issues-open.json")" "every issue kept"
}
test_issues_label_encoded() {
  route "GET repos/acme/app/issues?state=closed&per_page=100&labels=nl%3Astack%3Afoo" fx-issues-stack-notes.json
  eq "$(gh_issues acme/app closed nl:stack:foo | jq length)" 1
}

pr() { jq -c "{number: $1, state: \"$2\", merged_at: $3, head: {ref: \"b\"}}" <<< null; }
test_branch_pr_pick() {
  local k="GET repos/acme/app/pulls?state=all&head=acme%3Aovernight%2Fx&per_page=100"
  printf '[%s,%s,%s]' "$(pr 3 closed null)" "$(pr 5 open null)" "$(pr 4 closed '"2026-01-01T00:00:00Z"')" > "$TMP/a.json"
  route "$k" "$TMP/a.json"
  eq "$(gh_branch_pr acme/app overnight/x | jq .number)" 5 "open PR wins"
  : > "$GH_STUB_DIR/routes"; printf '[%s,%s]' "$(pr 3 closed null)" "$(pr 4 closed '"2026-01-01T00:00:00Z"')" > "$TMP/b.json"; route "$k" "$TMP/b.json"
  eq "$(gh_branch_pr acme/app overnight/x | jq .number)" 4 "else the newest"
  : > "$GH_STUB_DIR/routes"; echo '[]' > "$TMP/c.json"; route "$k" "$TMP/c.json"
  eq "$(gh_branch_pr acme/app overnight/x)" null "none"
  : > "$GH_STUB_DIR/routes"; route "$k" '!1 dial tcp: timeout'
  gh_branch_pr acme/app overnight/x >/dev/null 2>&1 && fail "gh failure must fail"
  return 0
}
test_branch_pr_real_fixture() {
  jq '[.[] | select(.head.ref == "feat/cloud-session-skills")]' "$GH_STUB_FIXTURES/nl-pulls-all.json" > "$TMP/f.json"
  route "GET repos/c0d3ster/nightlight/pulls?state=all&head=c0d3ster%3Afeat%2Fcloud-session-skills&per_page=100" "$TMP/f.json"
  eq "$(gh_branch_pr c0d3ster/nightlight feat/cloud-session-skills | jq -r '"\(.number) \(.state)"')" "137 open"
}

test_write_runs_and_dry_run() {
  gh_write -X POST repos/acme/app/labels -f name=x >/dev/null
  has "$(calls)" "-X POST repos/acme/app/labels -f name=x"
  : > "$GH_STUB_DIR/calls"
  local err; err="$(DRY_RUN=1 gh_write -X PATCH repos/acme/app/issues/3 -f title='a b' 2>&1)"
  eq "$(calls)" "" "dry run calls nothing"
  has "$err" "DRY_RUN: gh api -X PATCH repos/acme/app/issues/3 -f title=a\\ b"
}

test_delete_branch() {
  local c; c="$(make_repo acme/app)"
  git -C "$c" push -q origin main:refs/heads/overnight/x
  gh_delete_branch "$c" overnight/x || fail "delete should succeed"
  git -C "$c" ls-remote --exit-code --heads origin overnight/x >/dev/null && fail "branch still on origin"
  git -C "$c" push -q origin main:refs/heads/overnight/y
  git -C "$TMP/git/acme/app.git" config receive.denyDeletes true
  local err; err="$(gh_delete_branch "$c" overnight/y 2>&1)" && fail "refused delete must return 1"
  has "$err" "warning: couldn't delete branch overnight/y on origin"
  err="$(DRY_RUN=1 gh_delete_branch "$c" overnight/y 2>&1)" || fail "dry run returns 0"
  has "$err" "DRY_RUN: git -C $c push --quiet origin --delete overnight/y"
  gh_delete_branch "$c" 'x;rm' 2>/dev/null; eq "$?" 2 "unsafe name"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
