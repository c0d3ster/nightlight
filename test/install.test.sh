#!/usr/bin/env bash
# install.sh with HOME pointed at a temp dir. Windows (Git Bash) can't be tested here.
source "$(dirname "$0")/helpers.sh"
SK="$NL/.claude/skills" AG="$NL/.claude/agents"
run() { HOME="$TMP/home" bash "$NL/install.sh" "$@"; }

test_install_and_rerun() {
  local out; out="$(run)"
  local s; for s in "$SK"/*/; do s="$(basename "$s")"
    eq "$(readlink "$TMP/home/.claude/skills/$s")" "$SK/$s" "skill $s linked"; done
  for s in "$AG"/*.md; do eq "$(readlink "$TMP/home/.claude/agents/$(basename "$s")")" "$s" "agent linked"; done
  has "$out" "Linked: plan-tasks -> $SK/plan-tasks"; has "$out" "Done."
  out="$(run)"; has "$out" "Already linked: plan-tasks"; lacks "$out" "Linked:"
}
test_existing_entries() {
  mkdir -p "$TMP/home/.claude/skills/plan-tasks" "$TMP/home/.claude/skills/tidy-issues" "$TMP/home/.claude/agents" "$TMP/elsewhere/migrate-tasks"
  touch "$TMP/home/.claude/skills/plan-tasks/SKILL.md"; echo mine > "$TMP/home/.claude/skills/tidy-issues/notes"
  echo old > "$TMP/home/.claude/agents/task-scout.md"
  ln -s "$TMP/elsewhere/migrate-tasks" "$TMP/home/.claude/skills/migrate-tasks"
  ln -s /gone/.claude/skills/discover-tasks "$TMP/home/.claude/skills/discover-tasks"
  local out; out="$(run)"
  has "$out" "Replacing copy with symlink: plan-tasks"; has "$out" "Replacing copy with symlink: task-scout.md"
  has "$out" "Skipped: tidy-issues"; eq "$(cat "$TMP/home/.claude/skills/tidy-issues/notes")" mine "not a copy: untouched"
  has "$out" "Skipped: migrate-tasks (links to $TMP/elsewhere/migrate-tasks"
  eq "$(readlink "$TMP/home/.claude/skills/migrate-tasks")" "$TMP/elsewhere/migrate-tasks" "foreign link untouched"
  has "$out" "Replacing stale link: discover-tasks"
}
test_unlink() {
  run >/dev/null; ln -s "$TMP/x" "$TMP/home/.claude/skills/foreign"
  local out; out="$(run --unlink)"
  has "$out" "Unlinked: plan-tasks"; has "$out" "Unlinked: task-scout.md"
  eq "$(ls "$TMP/home/.claude/skills")" foreign "only links into this checkout removed"
  eq "$(ls "$TMP/home/.claude/agents")" ""
}
test_copy_instead_of_link_fails() {
  # Stand in for Git Bash without symlink support: an ln that copies.
  mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\n[[ "$1" == -s ]] && shift\ncp -r "$1" "$2"\n' > "$TMP/bin/ln"; chmod +x "$TMP/bin/ln"
  local out; out="$(PATH="$TMP/bin:$PATH" run 2>&1)"; eq "$?" 1 "fails"
  has "$out" "ln -s made a copy"; has "$out" "enable Developer Mode"
  [[ -e "$TMP/home/.claude/skills/discover-tasks" ]] && fail "copy left behind"
  return 0
}
test_msys_setting() {
  has "$(sed -n '/MSYSTEM/,/^fi/p' "$NL/install.sh")" 'MSYS="${MSYS:-winsymlinks:nativestrict}"'
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
done_testing
