#!/usr/bin/env bash
# Path helpers for the entry scripts. Each script sets NL_CALLER_PWD to the
# caller's directory before it cd's into nightlight, so a relative repo
# argument means what the caller meant.

# nl_abspath <dir>: absolute path. Git Bash's pwd -W gives the uppercase drive
# letter form (C:/...) that Claude Code's directory-trust store matches; other
# platforms don't have -W and use pwd -P.
nl_abspath() { (cd "$1" 2>/dev/null && { pwd -W 2>/dev/null || pwd -P; }); }

# nl_resolve_repo <arg>: the target repo as an absolute path, or fails. In
# order: an absolute path; "." or a relative path, against NL_CALLER_PWD;
# nightlight's own folder name (this checkout); a bare name under
# PROJECT_REPOS_DIR, else in NL_CALLER_PWD.
nl_resolve_repo() {
  local a="$1" here="${NL_CALLER_PWD:-$PWD}" nl
  nl="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ "$a" == /* || "$a" =~ ^[A-Za-z]:[\\/] ]]; then nl_abspath "$a"
  elif [[ "$a" == . || "$a" == .. || "$a" == ./* || "$a" == ../* || "$a" == */* ]]; then nl_abspath "$here/$a"
  elif [[ "$a" == "$(basename "$nl")" ]]; then nl_abspath "$nl"
  elif [[ -d "${PROJECT_REPOS_DIR:-}/$a" ]]; then nl_abspath "$PROJECT_REPOS_DIR/$a"
  else nl_abspath "$here/$a"
  fi || { echo "error: can't find repo '$a' (a path, or a folder under PROJECT_REPOS_DIR)" >&2; return 1; }
}
