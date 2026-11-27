#!/usr/bin/env bash
# lib/merge-pr.sh: branch scoping, rebase merge by REST, best-effort branch delete.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/github.sh"
B=chore/tasks-plan-2026-11-27
open_pr() { route "GET repos/acme/app/pulls?state=open&head=$(gh_uri "acme:$B")" "$1"; }

test_merges_and_deletes() {
  local c; c="$(make_repo acme/app)"; git -C "$c" push -q origin "main:refs/heads/$B"
  echo '[{"number": 41, "state": "open"}]' > "$TMP/o.json"; open_pr "$TMP/o.json"
  local out; out="$(bash "$NL/lib/merge-pr.sh" "$c" "$B")" || fail "exit status"
  has "$out" "merged #41 ($B) with rebase"
  has "$(calls)" "-X PUT repos/acme/app/pulls/41/merge -f merge_method=rebase"
  git -C "$c" ls-remote --exit-code --heads origin "$B" >/dev/null && fail "branch still on origin"
  return 0
}
test_refused_delete_still_succeeds() {
  local c; c="$(make_repo acme/app)"; git -C "$c" push -q origin "main:refs/heads/$B"
  git -C "$TMP/git/acme/app.git" config receive.denyDeletes true
  echo '[{"number": 41}]' > "$TMP/o.json"; open_pr "$TMP/o.json"
  bash "$NL/lib/merge-pr.sh" "$c" "$B" >/dev/null 2>"$TMP/e" || fail "a refused delete must not fail the merge"
  has "$(cat "$TMP/e")" "warning: couldn't delete branch $B on origin"
}
test_refuses_other_branches() {
  local c; c="$(make_repo acme/app)"
  for b in main overnight/2026-11-27/r1-01-t1-x chore/tasks-plan-; do
    bash "$NL/lib/merge-pr.sh" "$c" "$b" 2>/dev/null; eq "$?" 2 "refuses $b"
  done
  eq "$(calls)" "" "no API call"
}
test_no_open_pr_and_merge_failure() {
  local c; c="$(make_repo acme/app)"
  echo '[]' > "$TMP/n.json"; open_pr "$TMP/n.json"
  bash "$NL/lib/merge-pr.sh" "$c" "$B" 2>"$TMP/e"; eq "$?" 1; has "$(cat "$TMP/e")" "no open pull request"
  : > "$GH_STUB_DIR/routes"; echo '[{"number": 41}]' > "$TMP/o.json"; open_pr "$TMP/o.json"
  route "PUT repos/acme/app/pulls/41/merge" '!1 gh: Required status check "ci" is expected (HTTP 405)'
  bash "$NL/lib/merge-pr.sh" "$c" "$B" >/dev/null 2>&1; eq "$?" 1 "merge failure fails"
}
test_dry_run() {
  local c; c="$(make_repo acme/app)"; echo '[{"number": 41}]' > "$TMP/o.json"; open_pr "$TMP/o.json"
  local err; err="$(DRY_RUN=1 bash "$NL/lib/merge-pr.sh" "$c" "$B" 2>&1 >/dev/null)"
  has "$err" "DRY_RUN: gh api -X PUT repos/acme/app/pulls/41/merge -f merge_method=rebase"
  has "$err" "DRY_RUN: git -C $c push --quiet origin --delete $B"
  eq "$(ncalls PUT)" 0
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
