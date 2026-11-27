#!/usr/bin/env bash
# PreToolUse hook: applies nightlight's .claude/settings.json deny list to a
# session that isn't running from nightlight (a skill invoked inside another
# repo, or a future plugin). Skills can't ship permission rules, but their
# frontmatter hooks can deny, so each skill registers this when it runs.
#
# Reads the hook's JSON on stdin; prints a deny decision when the call matches a
# deny rule, nothing otherwise (the normal permission flow then decides). The
# matching mirrors the rule text, like the settings rules themselves: a Bash
# command is checked whole and per part of a chain (&&, ||, ;, |, newline), a
# Read path by its basename, an MCP tool by name (case-insensitive).

settings="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.claude/settings.json"
input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<< "$input")"

deny() {
  jq -cn --arg r "nightlight denies this ($1, from its .claude/settings.json)" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# matches <text> <rule-pattern>: the rule's glob, with a trailing ":*" meaning
# "starts with".
matches() {
  local text="$1" pat="$2"
  [[ "$pat" == *':*' ]] && pat="${pat%:\*}*"
  # shellcheck disable=SC2053 # the pattern is a glob on purpose
  [[ "$text" == $pat ]]
}

mapfile -t rules < <(jq -r '.permissions.deny[]?' "$settings" 2>/dev/null)
[[ ${#rules[@]} -gt 0 ]] || { echo "nightlight guard: can't read deny rules from $settings" >&2; exit 2; }

case "$tool" in
  Bash)
    cmd="$(jq -r '.tool_input.command // empty' <<< "$input")"
    mapfile -t parts < <(printf '%s\n' "$cmd" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}' | sed -E 's/^[[:space:](]+//; s/[[:space:])]+$//')
    for rule in "${rules[@]}"; do
      [[ "$rule" == 'Bash('*')' ]] || continue
      pat="${rule#Bash(}"; pat="${pat%)}"
      matches "$cmd" "$pat" && deny "$rule"
      for part in "${parts[@]}"; do [[ -n "$part" ]] && matches "$part" "$pat" && deny "$rule"; done
    done ;;
  Read)
    path="$(jq -r '.tool_input.file_path // empty' <<< "$input")"
    for rule in "${rules[@]}"; do
      [[ "$rule" == 'Read('*')' ]] || continue
      pat="${rule#Read(}"; pat="${pat%)}"
      matches "${path##*/}" "$pat" && deny "$rule"
    done ;;
  mcp__*)
    for rule in "${rules[@]}"; do
      [[ "${rule,,}" == "${tool,,}" ]] && deny "$rule"
    done ;;
esac
exit 0
