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
# discover parses the PRD format write-prd defines, and plan-tasks writes the
# reference discover dedupes on: keep the pointer and the spelling in step.
test_prd_contract() {
  local ref='PRD: docs/prd/<file> <unit>' f
  grep -q '^## Format' .claude/skills/write-prd/SKILL.md || fail "write-prd has no Format section"
  has "$(cat .claude/skills/discover-tasks/SKILL.md)" '.claude/skills/write-prd/SKILL.md` (Format)' "discover points at the format"
  for f in discover-tasks plan-tasks write-prd; do has "$(cat ".claude/skills/$f/SKILL.md")" "$ref" "$f PRD reference"; done
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
