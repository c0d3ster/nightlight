#!/usr/bin/env bash
# lib/paths.sh: repo resolution from the caller's directory, on any platform.
source "$(dirname "$0")/helpers.sh"
source "$NL/lib/paths.sh"

setup() { mkdir -p "$TMP/repos/app" "$TMP/work/here/sub" "$TMP/repos/here"; PROJECT_REPOS_DIR="$TMP/repos" NL_CALLER_PWD="$TMP/work/here"; }

test_abspath_works_without_pwd_W() {
  eq "$(nl_abspath "$TMP")" "$(cd "$TMP" && pwd -P)"
  nl_abspath "$TMP/missing" && fail "missing dir fails"
  return 0
}
test_relative_paths_use_the_callers_dir() {
  setup
  eq "$(nl_resolve_repo .)" "$TMP/work/here" "dot is the caller's repo, not nightlight"
  eq "$(nl_resolve_repo ./sub)" "$TMP/work/here/sub"
  eq "$(nl_resolve_repo ../here)" "$TMP/work/here"
}
test_names_and_absolute_paths() {
  setup
  eq "$(nl_resolve_repo app)" "$TMP/repos/app" "bare name under PROJECT_REPOS_DIR"
  eq "$(nl_resolve_repo here)" "$TMP/repos/here" "PROJECT_REPOS_DIR wins for a bare name"
  eq "$(nl_resolve_repo "$TMP/repos/app")" "$TMP/repos/app"
  eq "$(nl_resolve_repo "$(basename "$NL")")" "$(cd "$NL" && pwd -P)" "nightlight's own name"
  PROJECT_REPOS_DIR="$TMP/none"; eq "$(nl_resolve_repo sub)" "$TMP/work/here/sub" "bare name falls back to the caller's dir"
}
test_missing_repo_fails() {
  setup
  local err; err="$(nl_resolve_repo nope 2>&1)" && fail "should fail"
  has "$err" "can't find repo 'nope'"
}
test_scripts_use_the_helpers() {
  local f
  for f in plan.sh discover.sh migrate.sh tidy.sh overnight.sh; do
    has "$(sed -n '1,/^cd "\$(dirname "\$0")"/p' "$NL/$f")" 'NL_CALLER_PWD=' "$f keeps the caller's dir"
    has "$(cat "$NL/$f")" 'source lib/paths.sh' "$f loads the helpers"
  done
  eq "$(grep -ln 'pwd -W' "$NL"/*.sh "$NL"/lib/*.sh | grep -v paths.sh)" "" "pwd -W only in lib/paths.sh"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
