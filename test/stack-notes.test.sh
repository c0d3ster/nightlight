#!/usr/bin/env bash
# lib/stack-notes.sh in throwaway git repos (a bare origin under $TMP), PR state from the gh stub.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/github.sh"

prs() { # prs <branch> <state> <merged_at|null>: route that branch's PR list
  jq -cn --arg b "$1" --arg s "$2" --argjson m "$3" '[{number: 1, state: $s, merged_at: $m, head: {ref: $b}}]' > "$TMP/pr-${1//\//_}.json"
  route "GET repos/acme/app/pulls?state=all&head=$(gh_uri "acme:$1")&per_page=100" "$TMP/pr-${1//\//_}.json"
}
setup() {
  C="$(make_repo acme/app)"
  mkdir -p "$C/docs/stack-notes"
  printf '## #1 a\nBranch: overnight/d/r1-01-t1-a\n\n## #2 b\nBranch: overnight/d/r1-02-t2-b\n' > "$C/docs/stack-notes/done.md"
  printf '## #3 c\nBranch: overnight/d/r1-03-t3-c\n' > "$C/docs/stack-notes/open.md"
  printf 'no branches here\n' > "$C/docs/stack-notes/empty.md"
  git -C "$C" add -A && git -C "$C" commit -qm notes
  for b in overnight/d/r1-01-t1-a overnight/d/r1-02-t2-b overnight/d/r1-03-t3-c; do
    git -C "$C" branch -q "$b"; git -C "$C" push -q origin "$b"
  done
}
M='"2026-11-01T00:00:00Z"'

test_local_sweep() {
  setup
  prs overnight/d/r1-01-t1-a closed "$M"; prs overnight/d/r1-02-t2-b closed "$M"; prs overnight/d/r1-03-t3-c open null
  local out; out="$(bash "$NL/lib/stack-notes.sh" "$C")"
  has "$out" "deleted-branch overnight/d/r1-01-t1-a (local)"
  has "$out" "deleted-branch overnight/d/r1-02-t2-b (origin)"
  has "$out" "removed done"; has "$out" "kept open: overnight/d/r1-03-t3-c is open"; has "$out" "kept empty: no Branch: lines"
  eq "$(git -C "$C" diff --cached --name-status)" "D	docs/stack-notes/done.md" "only the finished file staged"
  git -C "$C" ls-remote --exit-code --heads origin overnight/d/r1-01-t1-a >/dev/null && fail "merged branch left on origin"
  git -C "$C" show-ref --quiet refs/heads/overnight/d/r1-03-t3-c || fail "open branch deleted"
}
test_keep_and_tasks_md() {
  setup
  prs overnight/d/r1-01-t1-a closed "$M"; prs overnight/d/r1-02-t2-b closed "$M"
  printf '## Agent-Ready\n- [!] #9 [stack: done] later\n' > "$C/TASKS.md"
  has "$(bash "$NL/lib/stack-notes.sh" "$C")" "kept done: still has open work" "open TASKS.md task keeps it"
  rm "$C/TASKS.md"
  has "$(bash "$NL/lib/stack-notes.sh" "$C" --keep done)" "kept done: still has open work" "--keep"
}
test_closed_unmerged_and_gh_failure() {
  setup
  prs overnight/d/r1-01-t1-a closed null
  route "GET repos/acme/app/pulls?state=all&head=$(gh_uri acme:overnight/d/r1-02-t2-b)&per_page=100" '!1 HTTP 502'
  local out; out="$(bash "$NL/lib/stack-notes.sh" "$C")"
  has "$out" "kept done: overnight/d/r1-01-t1-a is closed"; has "$out" "kept done: gh could not read the PR for overnight/d/r1-02-t2-b"
  eq "$(git -C "$C" diff --cached --name-only)" "" "nothing staged"
}
test_stale_entry_ignored() {
  setup
  echo '[]' > "$TMP/none.json"
  prs overnight/d/r1-01-t1-a closed "$M"
  route "GET repos/acme/app/pulls?state=all&head=$(gh_uri acme:overnight/d/r1-02-t2-b)&per_page=100" "$TMP/none.json"
  git -C "$C" branch -qD overnight/d/r1-02-t2-b; git -C "$C" push -q origin --delete overnight/d/r1-02-t2-b
  local out; out="$(bash "$NL/lib/stack-notes.sh" "$C")"
  has "$out" "ignored-stale overnight/d/r1-02-t2-b (no branch, no PR)"; has "$out" "removed done"
  route "GET repos/acme/app/pulls?state=all&head=$(gh_uri acme:overnight/d/r1-03-t3-c)&per_page=100" "$TMP/none.json"
  has "$out" "kept open: gh could not read" "no route = gh failure"
  has "$(bash "$NL/lib/stack-notes.sh" "$C")" "kept open: overnight/d/r1-03-t3-c has no PR" "branch exists, no PR"
}
test_refused_delete() {
  setup
  prs overnight/d/r1-01-t1-a closed "$M"; prs overnight/d/r1-02-t2-b closed "$M"
  git -C "$TMP/git/acme/app.git" config receive.denyDeletes true
  local out; out="$(bash "$NL/lib/stack-notes.sh" "$C")"
  has "$out" "delete-failed overnight/d/r1-01-t1-a (origin): couldn't delete branch overnight/d/r1-01-t1-a on origin"
  has "$out" "removed done" "a refused delete doesn't hold the stack"
}
test_remote_mode() {
  setup
  prs overnight/d/r1-01-t1-a closed "$M"; prs overnight/d/r1-02-t2-b closed "$M"
  mkdir "$TMP/n"; cp "$C/docs/stack-notes/done.md" "$TMP/n/"; printf 'Branch: overnight/d/r1-01-t1-a\n' > "$TMP/n/tracker-only.md"
  local out; out="$(bash "$NL/lib/stack-notes.sh" "$C" --remote "$TMP/n")"
  has "$out" "finished done"; has "$out" "removed-legacy done"; has "$out" "finished tracker-only"
  eq "$(git -C "$C" diff --cached --name-only)" "docs/stack-notes/done.md"
}
test_no_notes() { C="$(make_repo acme/app)"; has "$(bash "$NL/lib/stack-notes.sh" "$C")" "nothing to sweep"; }

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
