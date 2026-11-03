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

# Prints dir $1's env file candidates, most specific first (.env.local,
# .env.*.local, .env.*, .env), skipping templates that never hold real values.
_lk_candidates() {
  local dir="$1" f
  for f in "$dir/.env.local" "$dir"/.env.*.local "$dir"/.env.* "$dir/.env"; do
    [[ -f "$f" ]] || continue
    case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
    printf '%s\n' "$f"
  done | awk '!seen[$0]++'
}

# Prints the first candidate file in dir $1 that holds the key. Gitignored
# files are tried before the rest, because git itself says those are private.
_lk_find() {
  local dir="$1" f pass
  local -a files
  mapfile -t files < <(_lk_candidates "$dir")
  for pass in ignored other; do
    for f in "${files[@]}"; do
      if git -C "$dir" check-ignore -q "$f" 2>/dev/null; then
        [[ "$pass" == ignored ]] || continue
      else
        [[ "$pass" == other ]] || continue
      fi
      _lk_extract "$f" >/dev/null || continue
      printf '%s' "$f"
      return 0
    done
  done
  return 1
}

# Resolves LINEAR_API_KEY for repo $1 and exports it. Looks in the repo's env
# files, then nightlight's own (cwd), using the same rules for both: gitignored
# files first, then the rest, each most specific first. Extracts only the one
# key with grep, never sources a file. Warns when the file holding the key is
# tracked by git or not gitignored. Returns 1 if not found.
resolve_linear_key() {
  local repo="$1" dir src key
  for dir in "$repo" "."; do
    src="$(_lk_find "$dir")" || continue
    key="$(_lk_extract "$src")" || continue
    if git -C "$dir" ls-files --error-unmatch "${src#"$dir"/}" >/dev/null 2>&1; then
      echo "warn: LINEAR_API_KEY came from ${src#"$dir"/}, which is tracked by git (the key is committed)"
    elif ! git -C "$dir" check-ignore -q "$src" 2>/dev/null; then
      echo "warn: LINEAR_API_KEY came from ${src#"$dir"/}, which is not gitignored"
    fi
    export LINEAR_API_KEY="$key"
    return 0
  done
  echo "error: LINEAR_API_KEY not found in $repo env files or nightlight's own"
  return 1
}
