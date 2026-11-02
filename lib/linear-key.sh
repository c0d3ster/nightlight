#!/usr/bin/env bash
# LINEAR_API_KEY resolver, sourced by lib/task-source.sh (cwd must be the nightlight checkout).

# Prints the LINEAR_API_KEY value from file $1 (quotes and CR stripped), or fails if absent/empty.
_lk_extract() {
  local line
  line="$(grep -m1 '^LINEAR_API_KEY=' "$1" 2>/dev/null)" || return 1
  line="${line#LINEAR_API_KEY=}"
  line="${line%$'\r'}"
  line="${line#[\"\']}"; line="${line%[\"\']}"
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

# Resolves LINEAR_API_KEY for repo $1 and exports it. Searches the repo's env
# files (.env.local, .env.*.local, .env.*, .env; first match wins), then
# nightlight's own .env. Extracts only the one key with grep, never sources a
# file. Warns if the source file is tracked by git. Returns 1 if not found.
resolve_linear_key() {
  local repo="$1" f key="" src=""
  local -a candidates=("$repo/.env.local")
  for f in "$repo"/.env.*.local "$repo"/.env.*; do
    [[ -f "$f" ]] && candidates+=("$f")
  done
  candidates+=("$repo/.env")
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    if key="$(_lk_extract "$f")"; then src="$f"; break; fi
  done
  if [[ -z "$src" ]]; then
    # nightlight's own .env is gitignored, so no tracked-file warning
    if [[ -f .env ]] && key="$(_lk_extract .env)"; then
      export LINEAR_API_KEY="$key"
      return 0
    fi
    echo "error: LINEAR_API_KEY not found in $repo env files or nightlight's .env"
    return 1
  fi
  if git -C "$repo" ls-files --error-unmatch "${src#"$repo"/}" >/dev/null 2>&1; then
    echo "warn: LINEAR_API_KEY came from ${src#"$repo"/}, which is tracked by git (the key is committed)"
  fi
  export LINEAR_API_KEY="$key"
}
