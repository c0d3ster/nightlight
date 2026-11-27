#!/usr/bin/env bash
# Every script parses, and no script, skill, agent or CLAUDE.md calls gh's
# GraphQL commands (or gh api graphql).
source "$(dirname "$0")/helpers.sh"
cd "$NL" || exit 1

test_bash_n() { local f; for f in *.sh lib/*.sh test/*.sh test/bin/gh; do bash -n "$f" || fail "bash -n $f"; done; }
test_no_graphql_gh() {
  local hits
  hits="$(grep -nE 'gh (issue|pr|label|repo) (view|list|create|edit|close|comment|merge|delete)|gh api graphql' \
    *.sh lib/*.sh .claude/skills/*/SKILL.md .claude/agents/*.md CLAUDE.md)"
  eq "$hits" "" "GraphQL gh commands"
}
test_settings_json() {
  jq -e . .claude/settings.json >/dev/null || fail "settings.json invalid"
  eq "$(jq -r '.permissions.allow[] | select(test("gh (issue|pr|label) "))' .claude/settings.json)" "" "no GraphQL gh allows"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
