#!/usr/bin/env bash
# usage: bash test/run.sh [test/<name>.test.sh]...
# Runs every test file (or the ones named). Plain bash, needs git and jq; the gh
# stub in test/bin answers every GitHub call from test/fixtures.
cd "$(dirname "$0")/.." || exit 1
files=("$@"); [[ ${#files[@]} -gt 0 ]] || files=(test/*.test.sh)
failed=0
for f in "${files[@]}"; do
  echo "$f"
  bash "$f" || failed=$((failed+1))
done
[[ "$failed" == 0 ]] && echo "all test files passed" || { echo "$failed test file(s) failed"; exit 1; }
