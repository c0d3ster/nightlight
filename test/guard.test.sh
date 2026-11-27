#!/usr/bin/env bash
# lib/guard.sh, the PreToolUse hook the skills register, against the real
# deny list in .claude/settings.json.
source "$(dirname "$0")/helpers.sh"

# reason <tool> <command-or-path>: the deny reason, empty when allowed.
reason() {
  local key=command; [[ "$1" == Read ]] && key=file_path
  jq -cn --arg t "$1" --arg v "$2" --arg k "$key" '{tool_name: $t, tool_input: {($k): $v}}' \
    | bash "$NL/lib/guard.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}
denied() { has "$(reason "$1" "$2")" "${3:-nightlight denies}" "$1 $2 denied"; }
allowed() { eq "$(reason "$1" "$2")" "" "$1 $2 allowed"; }

test_git_rules() {
  denied Bash 'git push origin main' 'Bash(git push * main*)'
  denied Bash 'git push origin HEAD:refs/heads/main'
  denied Bash 'git -C /r push -f origin x'
  denied Bash 'git commit -m "x" --no-verify'
  denied Bash 'git commit -n -m x'
  denied Bash 'git -c core.hooksPath=/dev/null commit -m x'
  allowed Bash 'git push -u origin feat/main-menu'
  allowed Bash 'git commit -m "ok"'
}
test_chains_are_checked_per_part() {
  denied Bash 'npm test && git push --force origin x'
  denied Bash 'ls; git merge other'
  denied Bash 'echo x | git -C r push origin HEAD:main'
  denied Bash '(git merge other)'
  allowed Bash 'npm test && git status'
}
test_prefix_rules() {
  denied Bash 'rm -rf build' 'Bash(rm -rf:*)'
  allowed Bash 'rm build/out.txt'
}
test_gh_api_rules() {
  denied Bash 'gh api -X DELETE repos/a/b/git/refs/heads/x'
  denied Bash 'gh api -X PUT repos/a/b/pulls/3/merge -f merge_method=rebase'
  denied Bash 'gh api repos/a/b/contents/README.md'
  allowed Bash "gh api 'repos/a/b/pulls?state=all&per_page=100'"
  allowed Bash 'gh api -X POST repos/a/b/issues/3/comments -F body=@f'
}
test_read_rules() {
  denied Read /r/.env; denied Read /r/.env.local
  allowed Read /r/.envrc; allowed Read /r/src/env.ts
}
test_mcp_rules() {
  local out
  out="$(jq -cn '{tool_name: "mcp__Linear__delete_comment", tool_input: {}}' | bash "$NL/lib/guard.sh")"
  eq "$(jq -r .hookSpecificOutput.permissionDecision <<< "$out")" deny "MCP delete denied, any case"
  eq "$(jq -cn '{tool_name: "mcp__linear__save_comment", tool_input: {}}' | bash "$NL/lib/guard.sh")" "" "MCP save allowed"
}
test_other_tools_pass() {
  eq "$(jq -cn '{tool_name: "Edit", tool_input: {file_path: "/r/.env"}}' | bash "$NL/lib/guard.sh")" "" "only Read rules exist for .env"
}
test_unreadable_settings_blocks() {
  mkdir -p "$TMP/nl/lib" "$TMP/nl/.claude"; cp "$NL/lib/guard.sh" "$TMP/nl/lib/"; echo '{}' > "$TMP/nl/.claude/settings.json"
  echo '{"tool_name": "Bash", "tool_input": {"command": "ls"}}' | bash "$TMP/nl/lib/guard.sh" 2>/dev/null
  eq "$?" 2 "fails closed"
}
test_skills_and_agents_register_the_guard() {
  local f
  for f in "$NL"/.claude/skills/*/SKILL.md "$NL"/.claude/agents/*.md; do
    has "$(sed -n '/^---$/,/^---$/p' "$f")" 'lib/guard.sh' "$f registers the guard"
  done
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
