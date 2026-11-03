#!/usr/bin/env bash
# env_get VAR DIR...: prints VAR from the first env file in the first DIR that sets it, or fails.
# Reads one line, never sources. Files git reports as ignored are tried before the rest, each group in
# the order .env.local, .env.*.local, .env.*, .env; templates (.example/.sample/.template/.dist) are skipped.
# Warns on stderr when the value comes from a file that is not gitignored (tracked or not).
env_get() {
  local var="$1" dir f pass ig v; shift
  for dir; do
    for pass in 0 1; do
      for f in "$dir/.env.local" "$dir"/.env.*.local "$dir"/.env.* "$dir/.env"; do
        [[ -f $f ]] || continue
        case $f in *.example|*.sample|*.template|*.dist) continue ;; esac
        ig=1; git -C "$dir" check-ignore -q "$f" 2>/dev/null && ig=0
        [[ $ig == "$pass" ]] || continue
        v="$(sed -n "s/^$var=//p" "$f" | head -n1 | tr -d "\r\"'")"
        [[ -n $v ]] || continue
        (( ig )) && echo "warn: $var came from $f, which is not gitignored" >&2
        printf '%s' "$v"
        return 0
      done
    done
  done
  return 1
}
