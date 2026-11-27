#!/usr/bin/env bash
# Sourced by every test file. Puts the gh stub first on PATH, gives each test a
# fresh stub dir and scratch dir, and defines the assertions.
NL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$NL/test/bin:$PATH" GH_STUB_FIXTURES="$NL/test/fixtures"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
TESTS_RUN=0 TESTS_FAILED=0

# route "<METHOD> <endpoint>" <fixture...|"!<exit> <stderr>[|<stdout>]">
route() { local k="$1"; shift; printf '%s\t%s\n' "$k" "$*" >> "$GH_STUB_DIR/routes"; }
calls() { cat "$GH_STUB_DIR/calls" 2>/dev/null; }
ncalls() { calls | grep -c -- "${1:-.}" || true; }

fail() { echo "    FAIL: $*"; TEST_OK=0; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-values differ}"$'\n'"      expected: $(printf '%q' "$2")"$'\n'"      actual:   $(printf '%q' "$1")"; }
has() { [[ "$1" == *"$2"* ]] || fail "${3:-missing text}: $(printf '%q' "$2") not in $(printf '%q' "${1:0:400}")"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "${3:-unexpected text}: $(printf '%q' "$2")"; }

# A bare origin and a clone of it under $TMP: origin URL ends in <owner>/<name>.git
# so gh_slug reads "<owner>/<name>". Prints the clone path.
make_repo() {
  local slug="${1:-acme/app}" base="$TMP/git"
  mkdir -p "$base/${slug%/*}"
  git init -q --bare -b main "$base/$slug.git"
  git clone -q "$base/$slug.git" "$TMP/clone-${slug//\//-}" 2>/dev/null
  local c="$TMP/clone-${slug//\//-}"
  git -C "$c" commit -q --allow-empty -m init && git -C "$c" push -q origin main
  printf '%s\n' "$c"
}

# t <name> <function>: runs one test in a subshell with fresh dirs.
t() {
  TESTS_RUN=$((TESTS_RUN+1))
  local out
  out="$(
    TMP="$(mktemp -d)"; GH_STUB_DIR="$TMP/stub"; mkdir -p "$GH_STUB_DIR"; : > "$GH_STUB_DIR/routes"
    export TMP GH_STUB_DIR; TEST_OK=1
    "$2" 2>"$TMP/stderr"
    STDERR="$(cat "$TMP/stderr")"
    [[ "$TEST_OK" == 1 ]] || { echo "    stderr: ${STDERR:0:600}"; rm -rf "$TMP"; exit 1; }
    rm -rf "$TMP"
  )" && { echo "  ok   $1"; return 0; }
  TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL $1"; printf '%s\n' "$out"
}

done_testing() { echo "  $TESTS_RUN run, $TESTS_FAILED failed"; [[ "$TESTS_FAILED" == 0 ]]; }
