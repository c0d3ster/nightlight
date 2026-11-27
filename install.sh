#!/usr/bin/env bash
# usage: bash install.sh [--unlink]
#   Symlinks each .claude/skills/<name>/ (with a SKILL.md) into ~/.claude/skills
#   and each .claude/agents/<name>.md into ~/.claude/agents, so the skills run
#   from inside any repo. A stopgap until the plugin. Safe to repeat. Anything
#   already there that isn't an earlier link or copy of the same skill or agent
#   is skipped, never removed. --unlink removes only links into this checkout.
set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNLINK=0
[[ "${1:-}" == --unlink ]] && UNLINK=1

# Git Bash on Windows defaults to copying directories for `ln -s` unless
# winsymlinks is set to native mode. Developer Mode alone is not enough.
if [[ -n "${MSYSTEM:-}" || "${OSTYPE:-}" == msys* ]]; then
  export MSYS="${MSYS:-winsymlinks:nativestrict}"
fi

# link <source> <target>: is_copy says whether a non-link at <target> is an
# earlier copy of the same thing (safe to replace).
link() {
  local src="$1" target="$2" is_copy="$3" name; name="$(basename "$target")"

  if [[ "$UNLINK" == 1 ]]; then
    if [[ -L "$target" && "$(readlink "$target")" == "$src" ]]; then
      rm "$target"
      echo "Unlinked: $name"
    fi
    return
  fi

  if [[ -L "$target" ]]; then
    local cur; cur="$(readlink "$target")"
    if [[ "$cur" == "$src" ]]; then
      echo "Already linked: $name"
      return
    fi
    # Stale: dangling, or another nightlight checkout's copy of the same name.
    if [[ -e "$target" && "$cur" != */.claude/skills/"$name" && "$cur" != */.claude/agents/"$name" ]]; then
      echo "Skipped: $name (links to $cur, not a nightlight checkout)"
      return
    fi
    rm "$target"
    echo "Replacing stale link: $name"
  elif [[ -e "$target" ]]; then
    if ! eval "$is_copy"; then
      echo "Skipped: $name (exists and is not a copy of this one; move it aside to link)"
      return
    fi
    rm -rf "$target"
    echo "Replacing copy with symlink: $name"
  fi

  ln -s "$src" "$target"
  if [[ ! -L "$target" ]]; then
    rm -rf "$target"
    echo "error: ln -s made a copy of $name, not a symlink. On Windows, enable Developer Mode (Settings > System > For developers) and re-run." >&2
    exit 1
  fi
  echo "Linked: $name -> $src"
}

mkdir -p "$SKILLS_DIR" "$AGENTS_DIR"

for skill_dir in "$REPO_DIR"/.claude/skills/*/; do
  skill_dir="${skill_dir%/}"
  # Skip non-skill directories (no SKILL.md)
  [[ -f "$skill_dir/SKILL.md" ]] || continue
  link "$skill_dir" "$SKILLS_DIR/$(basename "$skill_dir")" '[[ -d "$target" && -f "$target/SKILL.md" ]]'
done

for agent in "$REPO_DIR"/.claude/agents/*.md; do
  [[ -f "$agent" ]] || continue
  # An earlier copy of an agent is a plain file with the same name.
  link "$agent" "$AGENTS_DIR/$(basename "$agent")" '[[ -f "$target" ]]'
done

echo "Done."
