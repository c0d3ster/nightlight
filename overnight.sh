#!/usr/bin/env bash
# usage: pnpm overnight [repo] [flags]
#   with repo: run that one repo
#   without:   run every repo under PROJECT_REPOS_DIR that has open TASKS.md work
#
# Dispatches one fresh `claude -p` subprocess per open TASKS.md task (plus one
# more for end-of-run housekeeping), instead of one continuous session across
# the whole run -- see CLAUDE.md's "Overnight Agent Workflow > Execution
# model" for why (context, and cache-read cost, no longer compound across
# every task in a run). Stacked tasks get their predecessor's context from
# the latest entry of docs/stack-notes/<stack>.md in the target repo (earlier
# entries are listed by heading only), not a raw diff/commit dump.
#
# flags (compose with the per-task prompt, they don't replace it):
#   --stop-after N        only complete tasks through #N (each task's permanent
#                          number, not a count or file position), then stop.
#   --limit N             only attempt N tasks this run (a count, not a task
#                          number), then stop. Works without a repo too: in
#                          "run every repo" mode, applies independently to
#                          each repo (first N tasks in each, in file order).
#   --stack <name>        only work tasks annotated [stack: <name>], skip every
#                          other stack this run.
#   --extra-instructions "<text>"
#                          append arbitrary free-form instructions to every
#                          task dispatched this run.
#   --override-prompt "<text>"
#                          bypass the per-task dispatch loop entirely and run
#                          ONE session with this exact prompt instead. Loses
#                          the housekeeping/workflow framing (and the task
#                          dispatch loop itself) unless <text> restates it --
#                          prefer the flags above.
#   --force               take over a repo that still has an overnight lock
#                          or leftover `claude -p` processes (kills them).
#                          Ctrl+C already does this for the active repo; use
#                          --force when a previous run survived the wrapper
#                          dying (closed window, Windows signal drop).
set -e
cd "$(dirname "$0")"

# Always run with the latest rules
git pull --quiet || echo "warn: could not pull latest nightlight rules, running with local copy"

set -a; source .env; set +a
: "${PROJECT_REPOS_DIR:?PROJECT_REPOS_DIR not set in .env}"
command -v jq >/dev/null || { echo "jq is required (see README Requirements)"; exit 1; }
source lib/task-source.sh

REPO=""
STOP_AFTER=""
LIMIT=""
STACK=""
EXTRA_INSTRUCTIONS=""
OVERRIDE_PROMPT=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --extra-instructions) EXTRA_INSTRUCTIONS="$2"; shift 2 ;;
    --override-prompt) OVERRIDE_PROMPT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --*) echo "unknown flag: $1"; exit 1 ;;
    *) REPO="$1"; shift ;;
  esac
done

# Ctrl+C / leftover-process guards. On Windows, SIGINT often kills this
# wrapper but not claude.exe, letting a second run mutate the same working
# tree. Lock per repo, refuse to start if a print-mode claude already
# targets it, and taskkill/kill on INT/TERM. Interactive claude sessions
# (no -p/--print) are left alone.
ACTIVE_REPO_PATH=""
LOCK_FILE=""

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ -n "${WINDIR:-}" ]]
}

# Spellings that may appear in claude's command line. Git Bash rewrites a
# POSIX --add-dir arg to drive-letter + forward-slashes (cygpath -m form,
# e.g. C:/Users/x) before a native .exe sees it -- confirmed empirically, so
# that's the only converted form generated here.
repo_path_needles() {
  local p="$1" m drive rest
  printf '%s\n' "$p"
  if command -v cygpath >/dev/null 2>&1; then
    m="$(cygpath -m "$p" 2>/dev/null)" && printf '%s\n' "$m"
  elif [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    printf '%s\n' "${drive^^}:/${rest}"
  fi
}

# Print-mode only -- plan/discover use --add-dir without -p/--print.
is_headless_repo_claude() {
  local cmdline="$1"; shift
  [[ "$cmdline" == *'--add-dir'* ]] || return 1
  [[ "$cmdline" == *' -p '* || "$cmdline" == *' --print '* ]] || return 1
  local needle
  for needle in "$@"; do
    [[ -z "$needle" ]] && continue
    # Require a boundary char after the needle (space, closing quote, or end
    # of string) so "web" doesn't match a "web-api" repo's process too.
    if [[ "$cmdline" == *"$needle "* || "$cmdline" == *"$needle"'"'* || "$cmdline" == *"$needle" ]]; then
      return 0
    fi
  done
  return 1
}

list_repo_claude_pids() {
  local repo_path="$1"
  local -a needles=()
  local n line pid cmdline ps1
  while IFS= read -r n; do
    [[ -n "$n" ]] && needles+=("$n")
  done < <(repo_path_needles "$repo_path")

  if is_windows; then
    ps1="powershell.exe"
    command -v powershell.exe >/dev/null 2>&1 || ps1="powershell"
    command -v "$ps1" >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
      line="${line%$'\r'}"
      pid="${line%% *}"
      cmdline="${line#* }"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      is_headless_repo_claude "$cmdline" "${needles[@]}" && echo "$pid"
    done < <("$ps1" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
      'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.Name -eq "claude.exe" -or $_.Name -eq "node.exe") } | ForEach-Object { "$($_.ProcessId) $($_.CommandLine)" }' 2>/dev/null)
  else
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      pid="${line%% *}"
      cmdline="${line#* }"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      is_headless_repo_claude "$cmdline" "${needles[@]}" && echo "$pid"
    done < <(ps -ax -o pid= -o args= 2>/dev/null || ps -eo pid= -o args=)
  fi
}

# Walks $1's descendants via ppid, POSIX only -- lets kill_pids reach a
# git/test/shell child a killed claude process leaves behind.
posix_descendant_pids() {
  local root="$1" pid
  echo "$root"
  for pid in $( (ps -ax -o pid=,ppid= 2>/dev/null || ps -eo pid=,ppid=) | awk -v p="$root" '$2==p {print $1}' ); do
    posix_descendant_pids "$pid"
  done
}

kill_pids() {
  local pid
  if is_windows; then
    for pid in "$@"; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      taskkill //T //F //PID "$pid" >/dev/null 2>&1 || true
    done
    return 0
  fi
  local -a all=()
  for pid in "$@"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    while IFS= read -r p; do all+=("$p"); done < <(posix_descendant_pids "$pid")
  done
  for pid in "${all[@]}"; do kill -INT "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${all[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${all[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
}

kill_repo_claude() {
  local repo_path="$1"
  local -a pids=()
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && pids+=("$pid")
  done < <(list_repo_claude_pids "$repo_path")
  [[ ${#pids[@]} -eq 0 ]] && return 0
  echo "stopping claude -p process tree(s) for $(basename "$repo_path"): ${pids[*]}"
  kill_pids "${pids[@]}"
}

release_lock() {
  if [[ -n "$LOCK_FILE" && -d "$LOCK_FILE" ]]; then
    rm -rf "$LOCK_FILE"
  fi
  LOCK_FILE=""
}

end_repo() {
  ACTIVE_REPO_PATH=""
  release_lock
}

# True only if $1 is a live overnight.sh run -- never ourselves (kill -0 on
# our own pid always succeeds, so a lock whose pid got reassigned to us
# would otherwise read as "still held"), and never an unrelated process that
# inherited a recycled pid. Falls back to trusting kill -0 alone if we can't
# inspect the process.
#
# On Windows, MSYS pids aren't real Windows pids (confirmed: $$ never
# matches a live Get-CimInstance listing), so a pid from our lock file needs
# `ps -l`'s WINPID column to resolve to something Get-CimInstance can find.
pid_is_overnight() {
  local pid="$1"
  [[ "$pid" == "$$" ]] && return 1
  if is_windows; then
    local winpid
    winpid="$(ps -p "$pid" -l 2>/dev/null | awk -v p="$pid" '$1==p {print $4}')"
    [[ "$winpid" =~ ^[0-9]+$ ]] || return 1
    local ps1="powershell.exe"
    command -v powershell.exe >/dev/null 2>&1 || ps1="powershell"
    command -v "$ps1" >/dev/null 2>&1 || return 0
    "$ps1" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
      "(Get-CimInstance Win32_Process -Filter \"ProcessId=$winpid\").CommandLine" 2>/dev/null \
      | grep -q 'overnight\.sh'
  else
    ps -p "$pid" -o args= 2>/dev/null | grep -q 'overnight\.sh'
  fi
}

# The lock is a directory, not a file: mkdir is atomic (POSIX and NTFS both
# refuse a second create of the same name), so it's the actual mutex -- a
# separate exists-check-then-write would leave a window for two invocations
# to both see no lock and both start.
acquire_lock() {
  local repo_path="$1" name="$2"
  # basename alone collides for two repos with the same name in different
  # parents (/work/a/api vs /archive/api); key the lock off the canonical
  # path too, keeping the basename only for readability.
  local canon; canon="$(cd "$repo_path" 2>/dev/null && pwd -P)" || canon="$repo_path"
  local lockdir="logs/$name-$(cksum <<< "$canon" | cut -d' ' -f1).overnight.lock"
  local lock="$lockdir/info"
  local old_pid
  local -a leftover_pids=()
  mkdir -p logs

  if ! mkdir "$lockdir" 2>/dev/null; then
    old_pid="$(sed -n 's/^pid=//p' "$lock" 2>/dev/null | head -n1)"
    old_pid="${old_pid//$'\r'/}"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && pid_is_overnight "$old_pid"; then
      if [[ "$FORCE" -ne 1 ]]; then
        echo "error: $name already has an overnight run (pid $old_pid, $lockdir)"
        echo "  Ctrl+C that terminal, or re-run with --force to take over"
        return 1
      fi
      echo "warn: --force: signaling overnight.sh pid $old_pid to stop"
      kill -TERM "$old_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$old_pid" 2>/dev/null || true
    else
      echo "warn: removing stale lock $lockdir (pid ${old_pid:-unknown} isn't a live overnight.sh)"
    fi
    rm -rf "$lockdir"
    if ! mkdir "$lockdir" 2>/dev/null; then
      echo "error: could not acquire lock for $name (another run just took it) -- try again"
      return 1
    fi
  fi

  while IFS= read -r old_pid; do
    [[ "$old_pid" =~ ^[0-9]+$ ]] && leftover_pids+=("$old_pid")
  done < <(list_repo_claude_pids "$repo_path")
  if [[ ${#leftover_pids[@]} -gt 0 ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
      echo "error: leftover claude -p process(es) still targeting $name (pids: ${leftover_pids[*]})"
      echo "  a previous run likely survived Ctrl+C. Re-run with --force to kill them first"
      rmdir "$lockdir" 2>/dev/null
      return 1
    fi
    echo "warn: --force: killing leftover claude -p process(es) for $name: ${leftover_pids[*]}"
    kill_repo_claude "$repo_path"
  fi

  {
    echo "pid=$$"
    echo "repo=$repo_path"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$lock"
  LOCK_FILE="$lockdir"
}

on_exit() {
  if [[ -n "$ACTIVE_REPO_PATH" ]]; then
    kill_repo_claude "$ACTIVE_REPO_PATH"
    ACTIVE_REPO_PATH=""
  fi
  release_lock
}

on_interrupt() {
  echo ""
  echo "interrupted: stopping this run"
  on_exit
  exit 130
}

trap on_interrupt INT TERM
trap on_exit EXIT

# Resolves a repo's default branch (main, master, or whatever origin/HEAD
# points to) so run_repo works on repos that never migrated off master.
default_branch() {
  local repo_path="$1"
  local ref
  ref="$(git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && { echo "${ref#origin/}"; return 0; }
  git -C "$repo_path" show-ref --verify --quiet refs/heads/main && { echo main; return 0; }
  git -C "$repo_path" show-ref --verify --quiet refs/heads/master && { echo master; return 0; }
  echo "error: could not determine default branch for $repo_path (no origin/HEAD, no main, no master)" >&2
  return 1
}


# Picks this run's number for today: 1 + the highest r<N> already used by an
# overnight/<today>/r<N>-* branch, local or on origin (1 if none). Keeps
# same-date runs from colliding on branch names and sorting into each other.
next_run_number() {
  local repo_path="$1" date="$2" max=0 n
  git -C "$repo_path" fetch --quiet origin 2>/dev/null || true
  while IFS= read -r n; do
    (( n > max )) && max=$n
  done < <(git -C "$repo_path" branch -a --list "*overnight/$date/r*" \
    | sed -nE "s#.*overnight/$date/r([0-9]+)-.*#\\1#p")
  echo $((max+1))
}

# Finds interrupted attempts at task $2: local branches named
# overnight/<date>/r<R>-<PP>-t<NN>-<slug> (NN = the task's own #<n>) that no
# PR was ever opened for. A session that finished opens its PR before exiting,
# so a branch with no PR means the session died mid-task (window closed,
# machine slept) before housekeeping could say anything about it. A branch
# with any PR (open, or merged/closed since) is left alone: that's "done,
# housekeeping hasn't run yet" or a human decision, not an interruption. If gh
# can't answer, the branch is skipped rather than risk discarding finished
# work. Prints one orphaned branch name per line.
find_orphan_branches() {
  local repo_path="$1" num="$2"
  local re="^overnight/[0-9]{4}-[0-9]{2}-[0-9]{2}/r[0-9]+-[0-9]+-t$num-"
  local b pr_count
  while IFS= read -r b; do
    [[ "${b,,}" =~ ${re,,} ]] || continue
    pr_count="$(cd "$repo_path" && gh pr list --head "$b" --state all --json number --jq length 2>/dev/null)" || continue
    [[ "$pr_count" == "0" ]] && echo "$b"
  done < <(git -C "$repo_path" for-each-ref --format='%(refname:short)' refs/heads/overnight refs/remotes/origin/overnight | sed 's#^origin/##' | sort -u)
}

# GitHub and Linear modes: an issue stays open until its task PR merges, so a
# task whose PR already exists (open, merged, or closed unmerged) must not be
# dispatched again. Prints "<state> #<pr>" for $2's PR (open or merged ones win
# over closed), nothing if it has none. The match is case-insensitive because a
# session may lowercase a Linear identifier in its branch name. One gh call per
# run, cached in TASK_PR_CACHE; returns 1 if gh can't answer.
TASK_PR_CACHE=""
find_task_pr() {
  local repo_path="$1" num="$2"
  if [[ -z "$TASK_PR_CACHE" ]]; then
    TASK_PR_CACHE="$(cd "$repo_path" && gh pr list --state all --limit 500 --json number,state,headRefName 2>/dev/null)" \
      || { TASK_PR_CACHE=""; return 1; }
  fi
  jq -r --arg re "^overnight/[0-9]{4}-[0-9]{2}-[0-9]{2}/r[0-9]+-[0-9]+-t$num-" '
    [.[] | select(.headRefName | test($re; "i"))]
    | (map(select(.state != "CLOSED")) + map(select(.state == "CLOSED"))) | first // empty
    | "\(.state | ascii_downcase) #\(.number)"' <<< "$TASK_PR_CACHE"
}

# Discards each orphaned branch (locally, and on origin if it was pushed) so
# the task retries from a clean state. Prints the discarded names, one per
# line, for the caller to hand to the retry prompt.
discard_orphan_branches() {
  local repo_path="$1" default_branch="$2" b
  shift 2
  git -C "$repo_path" checkout --quiet "$default_branch" || return 1
  for b in "$@"; do
    if git -C "$repo_path" rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
      git -C "$repo_path" branch -D "$b" >/dev/null || continue
    fi
    if git -C "$repo_path" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
      git -C "$repo_path" push --quiet origin --delete "$b" 2>/dev/null || true
    fi
    echo "$b"
  done
}

# Determines which branch a task should build on. solo tasks (and a stack's
# very first task ever) build on the repo's default branch; every later task
# in a stack builds on that stack's previous branch -- either dispatched
# earlier this run ($4, an associative array the caller maintains across the
# loop) or, resuming a stack from an earlier run, the last "Branch: " line
# recorded in its docs/stack-notes/<stack>.md.
#
# The stack-notes fallback can point at a branch whose own PR already merged
# into main (nothing retires it -- it just sits there as a stale tip until
# something rebases or deletes it). Chaining a new branch onto it would land
# that new work on a dead-end branch with no PR path into main, invisible
# from main once squash-merged. So before trusting that fallback, check
# whether it already has a merged PR; if so, re-root on the default branch
# instead. branch_map entries are same-run only and can't have merged yet
# (nothing merges mid-run), so they're trusted without the check.
resolve_base_branch() {
  local repo_path="$1" stack="$2" default_branch="$3"
  local -n branch_map="$4"

  if [[ "$stack" == "solo" ]]; then
    echo "$default_branch"
    return 0
  fi
  if [[ -n "${branch_map[$stack]:-}" ]]; then
    echo "${branch_map[$stack]}"
    return 0
  fi

  local notes_text="${5:-}"
  if [[ -n "$notes_text" ]]; then
    local prior_branch
    prior_branch="$(grep '^Branch: ' <<< "$notes_text" | tail -n1 | sed 's/^Branch: //')"
    if [[ -n "$prior_branch" ]]; then
      git -C "$repo_path" fetch --quiet origin "$prior_branch" 2>/dev/null || true
      if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$prior_branch" \
        || git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$prior_branch"; then
        local merged_at
        merged_at="$(cd "$repo_path" && gh pr view "$prior_branch" --json state,mergedAt --jq 'select(.state == "MERGED") | .mergedAt' 2>/dev/null)"
        if [[ -n "$merged_at" ]]; then
          echo "warn: stack '$stack''s recorded branch '$prior_branch' already merged into main (PR merged $merged_at) -- re-rooting on '$default_branch' instead of chaining onto a dead-end branch" >&2
        else
          echo "$prior_branch"
          return 0
        fi
      fi
    fi
  fi
  echo "$default_branch"
}

# Prints the part of a stack's notes (stdin) a stacked task's prompt embeds: the
# last "## " block (the immediate predecessor's entry), then a list of the
# earlier "## " headings. A file with no "## " heading is printed whole.
extract_latest_stack_note() {
  awk '
    /^## / { n++; heads[n] = $0; start = NR }
    { lines[NR] = $0 }
    END {
      if (!n) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      for (i = start; i <= NR; i++) print lines[i]
      if (n > 1) {
        print ""
        print "Earlier entries (headings only):"
        for (i = 1; i < n; i++) print "- " substr(heads[i], 4)
      }
    }
  '
}

# Is $2 still a branch that exists (local or origin) or one that has a PR? A
# retry discards an interrupted attempt's branch, which never had a PR, so its
# stack-notes entry is stale. Merged branches deleted by the sweep still have
# a PR and stay live. A gh failure counts as live (never drop an entry on doubt).
stack_branch_is_live() {
  local repo_path="$1" b="$2" n
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$b" && return 0
  git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$b" && return 0
  n="$(cd "$repo_path" && gh pr list --head "$b" --state all --json number --jq length 2>/dev/null)" || return 0
  [[ "$n" != "0" ]]
}

# Filters stack notes (stdin) down to live entries: drops each "## " entry whose
# "Branch: " branch is gone and never had a PR. Entries with no Branch: line
# stay. Prints the kept text.
filter_live_entries() {
  local repo_path="$1" block="" line
  git -C "$repo_path" fetch --quiet --prune origin 2>/dev/null || true
  flush_block() {
    [[ -n "$block" ]] || return 0
    local b; b="$(sed -n 's/^Branch: //p' <<< "$block" | head -n1)"
    b="${b%$'\r'}"
    if [[ -z "$b" ]] || stack_branch_is_live "$repo_path" "$b"; then
      printf '%s\n' "$block"
    else
      echo "warn: ignoring stack-notes entry for discarded branch '$b'" >&2
    fi
    block=""
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "## "* ]]; then flush_block; fi
    block="${block:+$block
}$line"
  done
  flush_block
}

# Loads stack $2's notes for a task prompt into STACK_NOTES_ALL (live entries
# as "## " blocks, newest last) and STACK_NOTES_REF (the tracker object to
# append to, empty if none). Plain globals, so call it without $(...). Local
# mode reads docs/stack-notes/<stack>.md. Remote modes read the tracker; with
# no tracker notes for the stack, a legacy docs/stack-notes/<stack>.md left from
# before notes moved is read as a fallback (read only, the session starts the
# tracker notes on its own entry). Returns 1 if the tracker can't be read, so
# the caller skips the task rather than let it start a duplicate notes object.
stack_notes_load() {
  local repo_path="$1" stack="$2" dir legacy="$1/docs/stack-notes/$2.md"
  STACK_NOTES_ALL="" STACK_NOTES_REF=""
  if [[ "$TASK_SOURCE" == local ]]; then
    [[ -f "$legacy" ]] && STACK_NOTES_ALL="$(tr -d '\r' < "$legacy")"
    return 0
  fi
  dir="$(mktemp -d)"
  if ! ts_stack_notes_export "$repo_path" "$dir" "$stack"; then
    rm -rf "$dir"
    return 1
  fi
  if [[ -e "$dir/$stack.ref" ]]; then
    STACK_NOTES_REF="$(tr -d '\r' < "$dir/$stack.ref")"
    STACK_NOTES_ALL="$(filter_live_entries "$repo_path" < "$dir/$stack.md")"
  elif [[ -f "$legacy" ]]; then
    STACK_NOTES_ALL="$(tr -d '\r' < "$legacy")"
  fi
  rm -rf "$dir"
}

# Builds the prompt for a single task's fresh subprocess: the task text
# verbatim, stack/stack-notes context (or the solo/no-stack-notes rule), any
# --extra-instructions, and the TASK_RESULT contract housekeeping consumes.
build_task_prompt() {
  local task_text="$1" num="$2" stack="$3" base_branch="$4" stack_notes="$5" position="$6" run="$7" retried="${8:-}" notes_ref="${9:-}"
  local remote_notes=0
  [[ "$TASK_SOURCE" != local ]] && remote_notes=1
  local entry_format="a heading with this task's number and title, a \"Branch: <your-branch-name>\" line, key decisions, interfaces/exports created, and any deviation from acceptance criteria"

  local p="A target repo has been added to this session via --add-dir. This is exactly ONE task from that repo's TASKS.md, dispatched by nightlight's overnight runner as its own fresh session -- you have no memory of any other task, past or future, in this run. Implement it per the \"Overnight Agent Workflow\" rules in the CLAUDE.md of THIS repo (nightlight, the one this session was launched from) -- branching, quality gates, PR, and NEEDS HUMAN/blocked handling all still apply exactly as documented there. Work this ONE task only, then stop: do not open, read for other purposes, or act on any other TASKS.md item, and do not perform end-of-session housekeeping -- a separate session handles that once, after every task dispatched this run is done.

Here is the task, verbatim from TASKS.md:

$task_text

This is run $run of today, dispatch position $position in it, so name your branch overnight/<YYYY-MM-DD>/r$run-$position-t$num-<task-slug> (position zero-padded to 2 digits, e.g. 01), per CLAUDE.md."

  if [[ "$stack" == "solo" ]]; then
    p="$p

This task is [stack: solo]: branch from the repo's default branch (currently checked out, at \"$base_branch\"), independent of every other task. Do not create or touch any docs/stack-notes/ file."
  elif [[ -n "$stack_notes" ]]; then
    local where="docs/stack-notes/$stack.md" older="The older entries are in docs/stack-notes/$stack.md on disk; read them only if you need them" finish
    if [[ "$remote_notes" == 1 ]]; then
      where="the stack's notes in the tracker"
      older="The older entries are in the tracker notes; fetch them only if you need them"
      finish="Before finishing, add your own entry to the stack's tracker notes in the same format used above (a \"## \" heading, with \"###\" or lower for any sub-headings inside the entry): $entry_format. $(ts_stack_notes_write_instructions "$stack" "$notes_ref") Do not create or edit docs/stack-notes/$stack.md, and do not commit the entry."
    else
      finish="Before finishing, append your own entry to docs/stack-notes/$stack.md (never rewrite earlier entries) in the same format used above (a \"## \" heading, with \"###\" or lower for any sub-headings inside the entry): $entry_format. Commit it as part of this task's own work, on this task's own branch."
    fi
    p="$p

This task continues stack \"$stack\". Branch your work from \"$base_branch\" (the latest branch already in this stack) instead of the repo's default branch. Below is the previous task's entry from $where (written by earlier tasks in this same stack), followed by the headings of any older entries -- use it as your context instead of inspecting their full diffs or commit history. $older:

---
$stack_notes
---

$finish"
  else
    local start
    if [[ "$remote_notes" == 1 ]]; then
      start="Before finishing, write your own entry to the stack's tracker notes (a \"## \" heading, then $entry_format -- later tasks in this stack will read it instead of your diff or commit history). $(ts_stack_notes_write_instructions "$stack" "$notes_ref") Do not create docs/stack-notes/$stack.md, and do not commit the entry."
    else
      start="Before finishing, create docs/stack-notes/$stack.md with your own entry: $entry_format -- later tasks in this stack will read this file instead of your diff or commit history. Commit it as part of this task's own work, on this task's own branch."
    fi
    p="$p

This task starts stack \"$stack\". Branch from the repo's default branch (currently checked out, at \"$base_branch\"). $start"
  fi

  if [[ "$TASK_SOURCE" == "github" ]]; then
    local repo_flag=""
    [[ -n "$TS_GITHUB_REPO" ]] && repo_flag=" --repo $TS_GITHUB_REPO"
    p="$p

This task is GitHub issue \`#$num\`; the text above is a synthesized snapshot. Read full detail and comments with \`gh issue view $num --comments$repo_flag\`. Reference the issue as \`#$num\` in backticks in the PR body, never use \`Closes #$num\` or any other closing keyword (closing is housekeeping's job), and never set status labels (nl:blocked, nl:needs-human) yourself; report status via TASK_RESULT only."
  fi

  if [[ "$TASK_SOURCE" == "linear" ]]; then
    p="$p

This task is Linear issue \`$num\`; the text above is a synthesized snapshot. Read full detail and comments with the Linear MCP tools (get_issue, list_comments). Reference the issue as \`$num\` in backticks in the PR body, never use a closing keyword or Linear magic word (closing is housekeeping's job), never edit the issue, and never set status labels (nl:blocked, nl:needs-human) yourself; report status via TASK_RESULT only."
  fi

  if [[ -d "${repo_path:-}/.claude" ]]; then
    p="$p

Files under .claude/ (skills, agents, commands) cannot be changed with the Edit or Write tools in this permission mode, and helper scripts written outside the repo are denied too. Change them with one inline Bash command that rewrites the file in place, for example \`python - <<'EOF' ... EOF\` or \`node -e\`. Do not modify .claude/settings.json or .claude/settings.local.json (a task must not grant itself permissions): report any permission change you need as a NEEDS HUMAN step with the exact entries in the PR description."
  fi

  if [[ -n "$retried" ]]; then
    p="$p

RETRY: an earlier session's attempt at this task was interrupted before it opened a PR (the branch scan found no PR for: $(printf '%s' "$retried" | tr '
' ' ')). Those branches have been discarded, so start from a clean state and treat this as the one retry allowed for this task."
  fi

  if [[ -n "$EXTRA_INSTRUCTIONS" ]]; then
    p="$p

IMPORTANT - special instructions for this run: $EXTRA_INSTRUCTIONS"
  fi

  p="$p

When you are done -- whether the task completed, needs a human step, or is blocked -- end your FINAL message with exactly one line, on its own, after everything else, nothing after it:
TASK_RESULT: $(ts_task_result_label "$num") status=<done|blocked|needs-human> branch=<branch-name-or-none> pr=<number-or-none> note=\"<one-line summary>\"
Use status=done when the PR is open and every acceptance criterion is met; status=needs-human when the PR is open but a manual step remains (put the exact steps in the PR description and TASKS.md per CLAUDE.md, keep note to a short pointer); status=blocked when you stopped before opening a PR (note explains why, per CLAUDE.md's blocked rules). This line is machine-parsed by this run's housekeeping session afterward -- match the format exactly, no markdown, no extra lines around it."

  printf '%s' "$p"
}

# Builds the prompt for the single end-of-run housekeeping subprocess: every
# dispatched task's TASK_RESULT line (collected by the caller across the
# loop), plus which tasks were filtered out and left untouched this run.
build_housekeeping_prompt() {
  local run_summary="$1" skipped_summary="$2" run="$3" keep_args="${4:-}" notes_dir="${5:-}"
  if [[ "$TASK_SOURCE" == "github" ]]; then
    build_housekeeping_prompt_github "$run_summary" "$skipped_summary" "$run" "$keep_args" "$notes_dir"
    return
  fi
  if [[ "$TASK_SOURCE" == "linear" ]]; then
    build_housekeeping_prompt_linear "$run_summary" "$skipped_summary" "$run" "$keep_args" "$notes_dir"
    return
  fi
  local p="A target repo has been added to this session via --add-dir. This session runs ONLY the end-of-session housekeeping step from the \"Overnight Agent Workflow\" rules in CLAUDE.md (this repo, nightlight's own) -- this run just finished dispatching one fresh session per task, so you were not present for any of them. Do not attempt any task work yourself. This is run $run of today, so name the housekeeping branch overnight/<YYYY-MM-DD>/r$run-housekeeping.

Here is what each dispatched task's own session reported when it finished, verbatim (one TASK_RESULT line per task attempted this run):
${run_summary:-"(no tasks were attempted this run)"}"

  if [[ -n "$skipped_summary" ]]; then
    p="$p

Tasks NOT attempted this run (filtered out by --stack/--stop-after/--limit) -- leave these exactly as-is in TASKS.md, they are neither done nor blocked, just out of scope this run:
$skipped_summary"
  fi

  p="$p

Treat the TASK_RESULT lines above as a starting point, not ground truth -- a task session can misreport, so confirm each PR/branch's actual state with git/gh before writing anything (e.g. gh pr view <pr> --json state,mergedAt, or gh pr list --head <branch>). Then follow the \"TASKS.md maintenance\" rules in CLAUDE.md exactly: check off or annotate each attempted task (NEEDS HUMAN / blocked as reported, with the note given), archive completed tasks to a new docs/tasks-archive/<date>.md, update tasksCompleted/tasksBlocked in docs/nightlight-meta.json, and open the housekeeping PR targeting main.

Before opening that PR, also run the stack-notes sweep, one deterministic script: bash lib/stack-notes.sh <target-repo-path>$keep_args (run it from this repo, nightlight; the target repo is the --add-dir). It deletes merged stack branches locally and on origin and git rms each finished stack's docs/stack-notes/<stack>.md, staged but not committed, so include those removals in the housekeeping commit and list them in the PR body. It reads TASKS.md itself for stacks with open tasks. Do not re-implement or second-guess its checks; report what it prints.

Also check every [/] (NEEDS HUMAN) line already in TASKS.md, not just ones reported this run -- per CLAUDE.md, check each one's PR merge state and archive+remove any that have since merged.

Also sweep every [!] (blocked) line in TASKS.md whose annotation blocks on a dependency (another task or a PR), not just ones reported this run -- per CLAUDE.md, check each referenced PR's merge state; if every dependency has merged, set the line back to [ ] and remove the BLOCKED annotation. Leave [!] lines blocked for any other reason, or whose gh check fails, exactly as they are.

Likewise sweep every [x] (checked off) line in TASKS.md, not just ones reported this run -- a task checked off by hand is complete but would otherwise sit in TASKS.md forever. Confirm each one's PR state with gh, then archive+remove it and count it in tasksCompleted (a [x] whose PR has not merged goes back to [/] instead)."

  printf '%s' "$p"
}

# GitHub-mode variant of build_housekeeping_prompt: the issues are the backlog,
# so no TASKS.md edits, no archive file, no counters (stats.sh counts from the
# nl:overnight label) and no stack-notes file (the tracker holds them). A normal
# run is tracker writes plus branch deletion with no PR; see the "Abnormal run"
# paragraph for the one case that commits.
build_housekeeping_prompt_github() {
  local run_summary="$1" skipped_summary="$2" run="$3" keep_args="${4:-}" notes_dir="${5:-}"
  local overnight_label stack_notes_label
  overnight_label="$(ts_gh_label overnight nl:overnight)"
  stack_notes_label="$(ts_gh_label stackNotes nl:stack-notes)"
  local repo_flag=""
  [[ -n "$TS_GITHUB_REPO" ]] && repo_flag=" --repo $TS_GITHUB_REPO"
  local blocked needs_human agent_ready verify research
  blocked="$(ts_gh_label blocked nl:blocked)"
  needs_human="$(ts_gh_label needsHuman nl:needs-human)"
  agent_ready="$(ts_gh_label agentReady nl:agent-ready)"
  verify="$(ts_gh_label verify nl:verify)"
  research="$(ts_gh_label research nl:research)"
  local p="A target repo has been added to this session via --add-dir. This session runs ONLY the end-of-session housekeeping step from the \"Overnight Agent Workflow\" rules in CLAUDE.md (this repo, nightlight's own) -- this run just finished dispatching one fresh session per task, so you were not present for any of them. Do not attempt any task work yourself. This is run $run of today, so name the housekeeping branch overnight/<YYYY-MM-DD>/r$run-housekeeping.

This repo's backlog is GitHub Issues (taskSource \"github\"): the issues, not TASKS.md, are the task list. Do NOT create or edit TASKS.md or any docs/tasks-archive/ file, and skip the TASKS.md-specific maintenance rules in CLAUDE.md (glyphs, [/] / [!] / [x] sweeps, archiving). Task numbers below are issue numbers. Pass$repo_flag to every gh issue command.

Here is what each dispatched task's own session reported when it finished, verbatim (one TASK_RESULT line per task attempted this run):
${run_summary:-"(no tasks were attempted this run)"}"

  if [[ -n "$skipped_summary" ]]; then
    p="$p

Tasks NOT attempted this run (filtered out by --stack/--stop-after/--limit) -- leave these issues exactly as-is, they are neither done nor blocked, just out of scope this run:
$skipped_summary"
  fi

  p="$p

Treat the TASK_RESULT lines above as a starting point, not ground truth -- a task session can misreport, so confirm each PR/branch's actual state with git/gh before changing any issue (e.g. gh pr view <pr> --json state,mergedAt, or gh pr list --head <branch> --state all). Then, per attempted task:
- PR merged: gh issue close <n> --reason completed with a comment linking the PR, add the $overnight_label label (see Counters below), and remove any status labels ($blocked, $needs_human) that no longer apply. Wrap issue numbers in backticks in comments you write.
- PR open, not merged: leave the issue open; no label change unless it reported needs-human.
- Reported done with pr=none (a Verify task that found the work already exists): gh issue close <n> --reason completed with the note as the comment.
- Reported blocked (no PR): add the $blocked label and comment the reason from the note.
- Reported needs-human: add the $needs_human label and comment the exact steps (from the task PR description), then leave it open.
Never close an issue whose PR has not merged, and never use a closing keyword to do it. The runner already created the nl:* labels, so don't create labels.

Also sweep every other open issue labeled $agent_ready, $verify or $research (this includes any also labeled $needs_human), not just ones reported this run: an earlier run's task PR may have merged since, and nothing else closes the issue. Task branches are named overnight/<date>/r<R>-<PP>-t<n>-<slug>, so find an issue's PR with gh pr list --state all --json number,state,headRefName,mergedAt$repo_flag and match -t<n>- in headRefName. If that PR merged, close the issue as completed with a PR-link comment, add the $overnight_label label and remove any status labels. If it is still open, or there is no PR, leave the issue alone.

Also flag, never silently resolve, any open issue carrying contradictory labels (e.g. $blocked together with $needs_human, or more than one section label): comment on the issue describing the conflict and mention it in your final message, but change no labels.

Counters: whenever you close an issue because its overnight/* task PR merged (the per-task PR-merged case and the sweep above, not the pr=none case), also add the $overnight_label label in the same step (gh issue edit <n> --add-label $overnight_label$repo_flag). stats.sh counts completions from that label, so do NOT touch docs/nightlight-meta.json or write any counter.

Stack notes live in the tracker, one tracking issue per stack titled \"stack-notes: <stack>\" (label $stack_notes_label), not in a file. After all the closes above, run the stack-notes sweep, one deterministic script: bash lib/stack-notes.sh <target-repo-path> --remote ${notes_dir:-<notes-dir>}$keep_args (run it from this repo, nightlight; the target repo is the --add-dir), adding one more --keep <name> for every stack that still has an open issue labeled nl:stack:<name>. It deletes merged stack branches locally and on origin and prints \"finished <stack>\" for each finished stack. For each finished stack, retitle its tracking issue: find it with gh issue list --label $stack_notes_label --state all --json number,title$repo_flag and run gh issue edit <number> --title \"[done] stack-notes: <stack>\"$repo_flag (skip one already prefixed [done]). Do not re-implement or second-guess the sweep's checks; report what it prints in your final message.

Abnormal run: a normal run commits nothing and opens NO PR; the tracker writes above and the branch deletions are the whole job. The one abnormal case is a \"removed-legacy <stack>\" line from the sweep, a docs/stack-notes/<stack>.md file left from before notes moved to the tracker, already staged with git rm. Only then create overnight/<YYYY-MM-DD>/r$run-housekeeping from main, commit the staged removals, and open a PR chore: session housekeeping <date> targeting main, listing the removed files in the body. Otherwise create no branch, no commit and no PR. Anything else odd (a failed gh call, a flagged label conflict) goes in your final message and the issue comments, not a PR.

Milestones: each non-solo stack is a GitHub milestone titled with the stack name. For every stack the sweep just reported as finished (same condition: every Branch: PR merged, no open nl:stack:<name> issue), close its milestone: find it with gh api 'repos/<owner>/<repo>/milestones?state=all' --paginate, then gh api -X PATCH repos/<owner>/<repo>/milestones/<number> -f state=closed (skip it if already closed). Never touch solo, and never close a milestone for a stack the sweep kept. A stack resumed this run (dispatched, or with an open nl:stack issue) whose milestone is closed gets reopened with -f state=open. If a gh api call fails, note it in your final message and continue; the label is authoritative."

  printf '%s' "$p"
}

# Linear-mode variant of build_housekeeping_prompt_github: same structure, but
# every tracker write goes through the Linear MCP tools instead of gh issue.
# PR state still comes from gh pr (the code lives on GitHub).
build_housekeeping_prompt_linear() {
  local run_summary="$1" skipped_summary="$2" run="$3" keep_args="${4:-}" notes_dir="${5:-}"
  local overnight_label
  overnight_label="$(ts_linear_label overnight nl:overnight)"
  local blocked needs_human agent_ready verify research
  blocked="$(ts_linear_label blocked nl:blocked)"
  needs_human="$(ts_linear_label needsHuman nl:needs-human)"
  agent_ready="$(ts_linear_label agentReady nl:agent-ready)"
  verify="$(ts_linear_label verify nl:verify)"
  research="$(ts_linear_label research nl:research)"
  local st_review st_done st_started st_queued status_rules
  st_review="$(ts_linear_status_for review)"; st_done="$(ts_linear_status_for done)"
  st_started="$(ts_linear_status_for started)"; st_queued="$(ts_linear_status_for queued)"
  status_rules="Statuses: the team's statuses are configured, not assumed. Review status: ${st_review:-none (never write one)}. Done status: ${st_done:-none (never write one, merged issues keep their current status)}. Whenever this prompt says to move an issue to one of them, pass that exact name as save_issue's state, after list_issue_statuses shows the team has it; if the team lacks it, skip the status move, note it in your final message, and still do the label and comment parts. A status move never replaces the label and comment rules."
  local status_restore=""
  if [[ -n "$st_queued$st_started$st_review" && -n "${LINEAR_LEDGER:-}" ]]; then
    status_restore="

Status ledger: the runner moved issues to ${st_queued:+\"$st_queued\" (queued) }${st_started:+\"$st_started\" (started) }${st_review:+\"$st_review\" (review) }and recorded each one's original status in $LINEAR_LEDGER (a JSON object mapping issue id to {original, set}; read it with the Read tool, and skip this whole section if the file is missing or empty). Never edit that file, the runner prunes it. For every entry, get_issue it and confirm its current status name equals its \"set\" value (otherwise someone already moved it: leave it). Then check its task PR (match the id case-insensitively in headRefName, as in the sweep below): merged means the PR-merged rule applies (Done); open means it stays in ${st_review:-its current status}; no PR or a PR closed unmerged means restore it with save_issue to the entry's \"original\" status name (a crash, --limit or a blocked task left it behind), and say so in your final message. A restored issue keeps any $blocked or $needs_human label it was given this run."
  fi
  local p="A target repo has been added to this session via --add-dir. This session runs ONLY the end-of-session housekeeping step from the \"Overnight Agent Workflow\" rules in CLAUDE.md (this repo, nightlight's own) -- this run just finished dispatching one fresh session per task, so you were not present for any of them. Do not attempt any task work yourself. This is run $run of today, so name the housekeeping branch overnight/<YYYY-MM-DD>/r$run-housekeeping.

This repo's backlog is Linear issues (taskSource \"linear\", team $TS_LINEAR_TEAM_ID): the issues, not TASKS.md, are the task list. Do NOT create or edit TASKS.md or any docs/tasks-archive/ file, and skip the TASKS.md-specific maintenance rules in CLAUDE.md. Task ids below are Linear identifiers (e.g. ENG-142). Make every tracker change through the Linear MCP tools (mcp__linear__*: list_issues, get_issue, save_issue, save_comment, list_issue_labels, create_issue_label, list_issue_statuses, list_documents, save_document; load their schemas first), never gh issue. gh is only for PR and branch state.

Here is what each dispatched task's own session reported when it finished, verbatim (one TASK_RESULT line per task attempted this run):
${run_summary:-"(no tasks were attempted this run)"}"

  if [[ -n "$skipped_summary" ]]; then
    p="$p

Tasks NOT attempted this run (filtered out by --limit) -- leave these issues exactly as-is, they are neither done nor blocked, just out of scope this run:
$skipped_summary"
  fi

  p="$p

Treat the TASK_RESULT lines above as a starting point, not ground truth -- a task session can misreport, so confirm each PR/branch's actual state with git/gh before changing any issue (e.g. gh pr view <pr> --json state,mergedAt, or gh pr list --head <branch> --state all). Then, per attempted task:
- PR merged: save_issue to move it to the Done status${st_done:+ (\"$st_done\")}, add the $overnight_label label (see Counters below) and drop any status labels ($blocked, $needs_human) that no longer apply, plus save_comment linking the PR. Labels set through save_issue replace the whole list, so read the issue's current labels first and resend the ones you keep. Wrap task ids in backticks in comments you write.
- PR open, not merged: save_issue to move it to the review status (skip when none is configured or it is already there); no label change unless it reported needs-human.
- Reported done with pr=none (a Verify task that found the work already exists): move it to the Done status with the note as the comment.
- Reported blocked (no PR): add the $blocked label and save_comment the reason from the note.
- Reported needs-human: add the $needs_human label and save_comment the exact steps (from the task PR description), then leave it open.
Never move an issue to Done unless its PR merged (or it is the pr=none case above). $status_rules$status_restore Before adding $blocked or $needs_human, create it with create_issue_label if list_issue_labels shows the team lacks it.

Also sweep every other open issue labeled $agent_ready, $verify or $research (this includes any also labeled $needs_human), not just ones reported this run: an earlier run's task PR may have merged since, and nothing else moves the issue. Task branches are named overnight/<date>/r<R>-<PP>-t<id>-<slug>, so find an issue's PR with gh pr list --state all --json number,state,headRefName,mergedAt and match the id case-insensitively in headRefName. If that PR merged, move the issue to the Done status with a PR-link comment, add the $overnight_label label and remove any status labels. If it is still open, move it to the review status if it is not there yet. With no PR, leave the issue alone.

Also flag, never silently resolve, any open issue carrying contradictory labels (e.g. $blocked together with $needs_human, or more than one section label): save_comment describing the conflict and mention it in your final message, but change no labels.

Counters: whenever you move an issue to Done (or, with no Done status configured, close it out by this rule) because its overnight/* task PR merged (the per-task PR-merged case and the sweep above, not the pr=none case), also add the $overnight_label label in the same save_issue call (create it with create_issue_label if list_issue_labels shows the team lacks it). stats.sh counts completions from that label, so do NOT touch docs/nightlight-meta.json or write any counter.

Stack notes live in the tracker, one Linear document per stack titled \"stack-notes: <stack>\" (in the stack's Project, or on the team when it has none), not in a file. After all the Done moves above, run the stack-notes sweep, one deterministic script: bash lib/stack-notes.sh <target-repo-path> --remote ${notes_dir:-<notes-dir>}$keep_args (run it from this repo, nightlight; the target repo is the --add-dir), adding one more --keep <name> for every stack that still has an open issue labeled nl:stack:<name>. It deletes merged stack branches locally and on origin and prints \"finished <stack>\" for each finished stack. For each finished stack, retitle its document: find it with list_documents (query \"stack-notes: <stack>\"), then save_document with its id and title \"[done] stack-notes: <stack>\" (skip one already prefixed [done]; never resend its content). Do not re-implement or second-guess the sweep's checks; report what it prints in your final message.

Abnormal run: a normal run commits nothing and opens NO PR; the tracker writes above and the branch deletions are the whole job. The one abnormal case is a \"removed-legacy <stack>\" line from the sweep, a docs/stack-notes/<stack>.md file left from before notes moved to the tracker, already staged with git rm. Only then create overnight/<YYYY-MM-DD>/r$run-housekeeping from main, commit the staged removals, and open a PR chore: session housekeeping <date> targeting main, listing the removed files in the body. Otherwise create no branch, no commit and no PR. Anything else odd (a failed tracker call, a flagged label conflict) goes in your final message and the issue comments, not a PR.

Milestones (read only): each non-solo stack maps to a Linear project milestone named after the stack, set on its issues by /plan-tasks. Never create a Project or milestone, and never touch solo. Linear derives a milestone's completed or open status from its issues (save_milestone has no state), so there is nothing to close or reopen. For each stack the sweep reported finished or that was dispatched this run, look the milestone up with list_projects (includeMilestones, team $TS_LINEAR_TEAM_ID) and just note in your final message any stack whose milestone is missing or appears in more than one Project. Skip quietly if it is fine."

  printf '%s' "$p"
}

# Scans a dispatch attempt's raw NDJSON for the most recent rate_limit_event
# and decides whether it reflects a hard block on the rolling five-hour usage
# window -- every session emits this event, blocked or not, so presence alone
# means nothing. rate_limit_info.status is one of "allowed", "allowed_warning"
# (approaching the limit, still succeeding), or "rejected" (the actual 429);
# only "rejected" counts. Scoped to rateLimitType == "five_hour" on purpose --
# a seven_day/weekly block isn't something an unattended run should sleep
# through, so that's left to the caller's normal failure handling instead.
# Sets RATE_LIMIT_RESETS_AT (plain, non-local -- this function's return value)
# to the reported resetsAt (unix seconds) when blocked, or "" otherwise.
check_rate_limit_block() {
  local raw_log="$1"
  RATE_LIMIT_RESETS_AT=""

  local info
  info="$(jq -c 'select(.type == "rate_limit_event") | .rate_limit_info' "$raw_log" 2>/dev/null | tail -n1)"
  [[ -z "$info" || "$info" == "null" ]] && return 0

  local status rate_type resets_at
  status="$(jq -r '.status // ""' <<< "$info")"
  rate_type="$(jq -r '.rateLimitType // ""' <<< "$info")"
  resets_at="$(jq -r '.resetsAt // empty' <<< "$info")"

  [[ "$status" == "rejected" && "$rate_type" == "five_hour" && -n "$resets_at" ]] && RATE_LIMIT_RESETS_AT="$resets_at"
  return 0
}

# Runs one claude -p subprocess with the given prompt against repo_path,
# streaming it live (through format-stream.jq) and appending it to the run's
# combined raw/readable/stderr logs. Sets DISPATCH_TMP_RAW (a plain, non-local
# assignment -- this is dispatch()'s other return value) to a temp file holding
# just the FINAL attempt's raw NDJSON, so the caller can pull a TASK_RESULT
# line out of exactly that attempt's output rather than the whole run's; the
# caller is responsible for rm-ing it afterward. Returns claude's own exit
# status from the final attempt (not the trailing tee's) so callers can tell a
# genuine claude failure (auth error, missing format-stream.jq, etc.) apart
# from a normal run.
#
# If an attempt is cut short by the rolling five-hour usage window (detected
# via check_rate_limit_block(), not just any failure), this pauses the whole
# nightlight process with `sleep` until the window's own reported resetsAt and
# retries the SAME prompt from scratch once the new window opens --
# "resume-on-new-window." Every attempt's raw output still lands in
# raw_log/errlog, even the paused ones. Capped at 3 pause-retries per call so
# a bad resetsAt (clock skew, a stale/misread event) can't hang the run
# forever; past that it falls through and returns the failed attempt like any
# other dispatch failure.
dispatch() {
  local prompt="$1" repo_path="$2" raw_log="$3" readable_log="$4" errlog="$5" run_log="${6:-/dev/null}"
  local pause_retries=0 claude_status=0

  while true; do
    DISPATCH_TMP_RAW="$(mktemp)"

    # The prompt goes in on stdin, not as a -p argument: Windows caps a command
    # line at ~32K chars, and a prompt can still blow past that (task text plus
    # stack-notes entry, retry notes) ("Argument list too long").
    printf '%s' "$prompt" \
      | claude \
      --add-dir "$repo_path" \
      --model sonnet \
      --permission-mode acceptEdits \
      --settings .claude/settings.json \
      --output-format stream-json \
      --verbose \
      -p \
      2>>"$errlog" \
      | tee "$DISPATCH_TMP_RAW" \
      | jq --unbuffered -r -f format-stream.jq \
      | tee -a "$readable_log" "$run_log"
    claude_status="${PIPESTATUS[1]}"

    cat "$DISPATCH_TMP_RAW" >> "$raw_log"

    # Append genuine tool/harness errors (is_error results - permission
    # denials, bad exit codes, missing files) from just this attempt to the
    # shared errlog.
    jq -r '
      select(.type == "user") | .message.content[]? |
      select(.type == "tool_result" and .is_error == true) |
      (if (.content | type) == "array" then
        (.content | map(.text? // "") | join(" "))
      else
        (.content | tostring)
      end) |
      gsub("\\[[0-9;]*[a-zA-Z]"; "")
    ' "$DISPATCH_TMP_RAW" >> "$errlog"

    check_rate_limit_block "$DISPATCH_TMP_RAW"
    local has_result
    has_result="$(jq -c 'select(.type == "result")' "$DISPATCH_TMP_RAW" | tail -n1)"

    # Only pause when the window block actually coincided with a failed/cut-
    # short attempt -- a "rejected" event that the CLI itself recovered from
    # (still exited 0 with a result) isn't worth pausing for.
    if [[ -z "$RATE_LIMIT_RESETS_AT" || ( "$claude_status" -eq 0 && -n "$has_result" ) || "$pause_retries" -ge 3 ]]; then
      break
    fi

    pause_retries=$((pause_retries+1))
    local resume_at wait_s human_time
    resume_at=$((RATE_LIMIT_RESETS_AT + 60))
    wait_s=$((resume_at - $(date +%s)))
    human_time="$(date -d "@$resume_at" 2>/dev/null || date -r "$resume_at" 2>/dev/null || echo "unix:$resume_at")"
    echo "pausing: five-hour usage window exhausted (pause-retry $pause_retries/3), resuming ~$human_time"
    rm -f "$DISPATCH_TMP_RAW"
    [[ "$wait_s" -gt 0 ]] && sleep "$wait_s"
  done

  return "$claude_status"
}

# Pulls the last "TASK_RESULT: ..." line out of a task subprocess's final
# assistant message(s). Empty if the subprocess never emitted one.
extract_task_result() {
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$1" \
    | grep -o 'TASK_RESULT:.*' | tail -n1
}

# Rolls this call's cost/duration/turns/cache-token usage (from the stream's
# closing "result" event) into stats/<repo>.json's running totals. Local-only,
# gitignored -- never committed, never touches the target repo. Called once
# per dispatched subprocess (each task, plus housekeeping), so "sessions" here
# means individual claude -p calls, not runs of overnight.sh. Sets
# US_COST/US_DURATION_S/US_TURNS/US_CACHE_READ/US_CACHE_CREATION/US_INPUT/US_OUTPUT (plain,
# non-local -- this function's return values) to this call's own numbers,
# zeroed if the result event was missing, for run_repo() to roll into a
# whole-run total.
update_stats() {
  local name="$1" raw_log="$2"
  mkdir -p stats
  local stats_file="stats/$name.json"
  local result_line; result_line="$(jq -c 'select(.type == "result")' "$raw_log" | tail -n1)"
  US_COST=0; US_DURATION_S=0; US_TURNS=0; US_CACHE_READ=0; US_CACHE_CREATION=0; US_INPUT=0; US_OUTPUT=0
  if [[ -z "$result_line" ]]; then
    echo "warn: no result event in $raw_log, skipping stats update"
    return 0
  fi
  local prev_json="{}"
  [[ -f "$stats_file" ]] && prev_json="$(cat "$stats_file")"
  jq -n \
    --argjson prev "$prev_json" \
    --argjson result "$result_line" \
    '{
      sessions: (($prev.sessions // 0) + 1),
      total_cost_usd: (($prev.total_cost_usd // 0) + $result.total_cost_usd),
      total_duration_s: (($prev.total_duration_s // 0) + ($result.duration_ms / 1000 | floor)),
      total_turns: (($prev.total_turns // 0) + $result.num_turns),
      total_cache_read_tokens: (($prev.total_cache_read_tokens // 0) + ($result.usage.cache_read_input_tokens // 0)),
      total_cache_creation_tokens: (($prev.total_cache_creation_tokens // 0) + ($result.usage.cache_creation_input_tokens // 0)),
      total_input_tokens: (($prev.total_input_tokens // 0) + ($result.usage.input_tokens // 0)),
      total_output_tokens: (($prev.total_output_tokens // 0) + ($result.usage.output_tokens // 0))
    }' > "$stats_file"

  US_COST="$(jq -n --argjson r "$result_line" '$r.total_cost_usd')"
  US_DURATION_S="$(jq -n --argjson r "$result_line" '$r.duration_ms / 1000 | floor')"
  US_TURNS="$(jq -n --argjson r "$result_line" '$r.num_turns')"
  US_CACHE_READ="$(jq -n --argjson r "$result_line" '$r.usage.cache_read_input_tokens // 0')"
  US_CACHE_CREATION="$(jq -n --argjson r "$result_line" '$r.usage.cache_creation_input_tokens // 0')"
  US_INPUT="$(jq -n --argjson r "$result_line" '$r.usage.input_tokens // 0')"
  US_OUTPUT="$(jq -n --argjson r "$result_line" '$r.usage.output_tokens // 0')"
}

# Structural self-check for stats/<repo>.json against docs/stats-schema.json
# (see that file's header re: no schema validator dependency here). Not
# exhaustive -- just enough to catch a future edit breaking the documented
# shape. Warns, never aborts a run.
validate_stats_shape() {
  local stats_file="$1"
  local err
  err="$(jq -r '
    def check(cond; msg): if cond then empty else msg end;
    [
      check(.sessions | type == "number"; "sessions missing or not a number"),
      check(.total_cost_usd | type == "number"; "total_cost_usd missing or not a number"),
      check(.total_duration_s | type == "number"; "total_duration_s missing or not a number"),
      check(.total_turns | type == "number"; "total_turns missing or not a number"),
      check((.lastSession | type) == "object"; "lastSession missing or not an object"),
      check((.lastSession.date | type) == "string"; "lastSession.date missing or not a string"),
      check((.lastSession.calls | type) == "number"; "lastSession.calls missing or not a number"),
      check((.lastSession.cost_usd | type) == "number"; "lastSession.cost_usd missing or not a number"),
      check((.lastSession.tasks | type) == "array"; "lastSession.tasks missing or not an array"),
      (.lastSession.tasks // [] | to_entries[] | . as $e |
        check(($e.value.taskNumber | type) as $t | $t == "number" or $t == "string"; "lastSession.tasks[\($e.key)].taskNumber missing or not a number/string"),
        check(($e.value.taskTitle | type) == "string"; "lastSession.tasks[\($e.key)].taskTitle missing or not a string"),
        check(($e.value.status | type) == "string"; "lastSession.tasks[\($e.key)].status missing or not a string")
      )
    ] | .[]
  ' "$stats_file" 2>&1)"
  if [[ -n "$err" ]]; then
    echo "warn: $stats_file doesn't match docs/stats-schema.json:"
    echo "$err" | sed 's/^/  - /'
  fi
}

# Appends this run's session object (same shape as lastSession) as one line
# to stats/<repo>-history.jsonl -- an append-only time series, unlike
# lastSession which is overwritten every run. Adds repo (self-describing if
# lines from multiple repos are ever concatenated) and ranAt (date alone
# doesn't disambiguate multiple runs on the same day).
append_session_history() {
  local name="$1" session_json="$2"
  jq -c --arg repo "$name" --arg ranAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {repo: $repo, ranAt: $ranAt}' <<< "$session_json" >> "stats/$name-history.jsonl"
}

# Writes this run_repo() invocation's whole-run totals (every dispatch this
# call made -- every attempted task plus housekeeping, accumulated by the
# caller from each update_stats() call's US_* values) into stats/<repo>.json
# as lastSession -- "what did this whole overnight run cost me," distinct
# from total_* (lifetime across every run_repo() invocation ever). tasks_json
# is a JSON array (built by the caller from record_task_entry(), "[]" if none
# -- e.g. override-prompt mode) giving per-task cost/turns/status at a
# glance. Also appends to stats/<repo>-history.jsonl via
# append_session_history().
record_session_totals() {
  local name="$1" calls="$2" cost="$3" duration_s="$4" turns="$5" cache_read="$6" cache_creation="$7" input="$8" output="$9" tasks_json="${10:-[]}"
  local stats_file="stats/$name.json"

  local session_obj
  session_obj="$(jq -n \
    --arg date "$(date +%F)" \
    --argjson calls "$calls" \
    --argjson cost "$cost" \
    --argjson duration_s "$duration_s" \
    --argjson turns "$turns" \
    --argjson cache_read "$cache_read" \
    --argjson cache_creation "$cache_creation" \
    --argjson input "$input" \
    --argjson output "$output" \
    --argjson tasks "$tasks_json" \
    '{
      date: $date,
      calls: $calls,
      cost_usd: $cost,
      duration_s: $duration_s,
      num_turns: $turns,
      cache_read_tokens: $cache_read,
      cache_creation_tokens: $cache_creation,
      input_tokens: $input,
      output_tokens: $output,
      tasks: $tasks
    }')"

  local prev_json="{}"
  [[ -f "$stats_file" ]] && prev_json="$(cat "$stats_file")"
  jq -n --argjson prev "$prev_json" --argjson session "$session_obj" \
    '$prev + {lastSession: $session}' > "$stats_file"

  validate_stats_shape "$stats_file"
  append_session_history "$name" "$session_obj"

  echo "=== $name: this run cost \$$cost across $calls subprocess call(s), $turns turns, $cache_read cache-read tokens ==="
}

# Linear status ledger for this run_repo() call (see ts_linear_move).
LINEAR_LEDGER=""

# Moves the issues this run will dispatch to the queued status, applying the
# same filters as the dispatch loop (--stack, --limit, existing task PR).
# Args: ledger, repo path, then the "<id>	<stack>	<file>" records.
queue_linear_tasks() {
  local ledger="$1" repo_path="$2"; shift 2
  [[ -n "$(ts_linear_status_for queued)" ]] || return 0
  local rec id stack n=0
  for rec in "$@"; do
    IFS=$'	' read -r id stack _ <<< "$rec"
    [[ -z "$STACK" || "$stack" == "$STACK" ]] || continue
    [[ -z "$LIMIT" || "$n" -lt "$LIMIT" ]] || break
    [[ -z "$(find_task_pr "$repo_path" "$id" 2>/dev/null)" ]] || continue
    ts_linear_move "$ledger" "$id" queued
    n=$((n+1))
  done
}

run_repo() {
  local repo_path="$1"
  # Canonicalize before naming anything off it: a relative arg like "."
  # or "../nightlight" must resolve to the real directory name (e.g.
  # "nightlight"), not literally "." or "..", or every log/stats file this
  # run produces gets misnamed. pwd -W, not plain pwd -P: this same
  # $repo_path is later passed straight to claude's --add-dir, and only
  # pwd -W's uppercase-drive-letter form matches the casing Claude Code's
  # directory-trust store uses elsewhere (see discover.sh/plan.sh, which
  # hit this same casing bug first).
  repo_path="$(cd "$repo_path" 2>/dev/null && pwd -W)" || { echo "error: can't resolve target repo path: $1"; return 1; }
  local name; name="$(basename "$repo_path")"
  local tasks="$repo_path/TASKS.md"
  load_task_source "$repo_path" || return 1
  if [[ -n "$STOP_AFTER" && "$TS_NUMERIC_IDS" != 1 ]]; then
    echo "error: --stop-after needs numeric task ids, and this task source uses opaque ids"; return 1
  fi

  [[ "$TASK_SOURCE" != local || -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; return 0; }
  local elig=0; ts_is_eligible "$repo_path" || elig=$?
  [[ $elig -ne 1 ]] || { echo "skip: $name (no open tasks)"; return 0; }
  [[ $elig -eq 0 ]] || { echo "error: $name: task source lookup failed (see above); skipping"; return 1; }

  acquire_lock "$repo_path" "$name" || return 1
  ACTIVE_REPO_PATH="$repo_path"

  echo "=== $name ==="
  # gh rejects labels that don't exist: create the nl:* set once so no prompt has to.
  [[ "$TASK_SOURCE" != github ]] || ts_gh_ensure_labels "$repo_path" || echo "warn: couldn't ensure nl:* labels; label writes may fail"
  local branch; branch="$(default_branch "$repo_path")" || { end_repo; return 1; }
  git -C "$repo_path" checkout "$branch" && git -C "$repo_path" pull

  # One folder per repo per day; each run's files are told apart by their
  # r<R>- prefix, matching the overnight/<date>/r<R>-... branch names.
  local today; today="$(date +%F)"
  local logdir="logs/$name/$today"
  mkdir -p "$logdir"
  local run_num; run_num="$(next_run_number "$repo_path" "$today")"
  local run_log="$logdir/r$run_num-run.log"

  if [[ -n "$OVERRIDE_PROMPT" ]]; then
    local base="$logdir/r$run_num-override"
    local errlog="$base.stderr.log"
    dispatch "$OVERRIDE_PROMPT" "$repo_path" "$base.jsonl" "$base.log" "$errlog" "$run_log" \
      || echo "warn: claude exited non-zero for $name's override-prompt session -- check $errlog"
    update_stats "$name" "$DISPATCH_TMP_RAW"
    rm -f "$DISPATCH_TMP_RAW"
    record_session_totals "$name" 1 "$US_COST" "$US_DURATION_S" "$US_TURNS" "$US_CACHE_READ" "$US_CACHE_CREATION"
    [[ -s "$errlog" ]] || rm -f "$errlog"
    end_repo
    return 0
  fi

  local blockdir; blockdir="$(mktemp -d)"
  local -a task_records=()
  while IFS=$'\t' read -r num stack blockfile; do
    task_records+=("$num"$'\t'"$stack"$'\t'"$blockfile")
  done < <(ts_list_tasks "$repo_path" "$blockdir")

  if [[ ${#task_records[@]} -eq 0 ]]; then
    echo "skip: $name (no tasks found in Agent-Ready/Verify/Research)"
    rm -rf "$blockdir"
    local discovered; discovered="$(ts_discovered_count "$repo_path")" || discovered=0
    end_repo
    if [[ "${discovered:-0}" -gt 0 ]]; then
      echo "$name has $discovered Discovered item(s) needing planning (run: pnpm plan $name)"
      # Discovered items never start work; planning only on an interactive terminal.
      if [[ -t 0 && -t 1 ]]; then
        local answer
        read -r -p "Run planning now? [y/N] " answer
        [[ "$answer" =~ ^[Yy] ]] && bash "$(dirname "$0")/plan.sh" "$name"
      fi
    fi
    return 0
  fi

  if [[ "$TASK_SOURCE" == linear ]]; then
    LINEAR_LEDGER="logs/$name/status-ledger.json"
    ts_linear_ledger_prune "$LINEAR_LEDGER"
    queue_linear_tasks "$LINEAR_LEDGER" "$repo_path" "${task_records[@]}"
  fi

  local -A stack_branch=()
  local attempted=0 pr_skipped=0 consecutive_failures=0
  TASK_PR_CACHE=""
  local run_summary="" skipped_summary="" ran_keep_args=""
  local session_calls=0 session_cost=0 session_duration=0 session_turns=0 session_cache_read=0 session_cache_creation=0 session_input=0 session_output=0

  # Folds one update_stats() call's US_* values into this run_repo()
  # invocation's running total. Called after every dispatch (each task plus
  # housekeeping) so record_session_totals() reflects the whole run.
  accumulate_session() {
    session_calls=$((session_calls+1))
    session_cost="$(awk -v a="$session_cost" -v b="$US_COST" 'BEGIN{print a+b}')"
    session_duration=$((session_duration+US_DURATION_S))
    session_turns=$((session_turns+US_TURNS))
    session_cache_read=$((session_cache_read+US_CACHE_READ))
    session_cache_creation=$((session_cache_creation+US_CACHE_CREATION))
    session_input=$((session_input+US_INPUT))
    session_output=$((session_output+US_OUTPUT))
  }

  # Appends one task's numbers (from the US_* just set by update_stats()) as
  # an entry in this run's tasks array. Only the per-task dispatch loop below
  # calls this -- housekeeping isn't a numbered task.
  local -a session_task_entries=()
  record_task_entry() {
    local num="$1" title="$2" status="$3"
    session_task_entries+=("$(jq -nc \
      --arg num "$num" \
      --arg title "$title" \
      --arg status "$status" \
      --argjson cost "$US_COST" \
      --argjson duration_s "$US_DURATION_S" \
      --argjson turns "$US_TURNS" \
      --argjson cache_read "$US_CACHE_READ" \
      --argjson cache_creation "$US_CACHE_CREATION" \
      --argjson input "$US_INPUT" \
      --argjson output "$US_OUTPUT" \
      '{taskNumber: (try ($num | tonumber) catch $num), taskTitle: $title, status: $status, cost_usd: $cost, duration_s: $duration_s, num_turns: $turns, cache_read_tokens: $cache_read, cache_creation_tokens: $cache_creation, input_tokens: $input, output_tokens: $output}')")
  }

  local rec num stack blockfile
  for rec in "${task_records[@]}"; do
    IFS=$'\t' read -r num stack blockfile <<< "$rec"

    if [[ -n "$STACK" && "$stack" != "$STACK" ]]; then
      skipped_summary="$skipped_summary
- #$num [stack: $stack]: out of scope this run (--stack $STACK)"
      continue
    fi
    if [[ -n "$STOP_AFTER" && "$num" -gt "$STOP_AFTER" ]]; then
      skipped_summary="$skipped_summary
- #$num: out of scope this run (--stop-after $STOP_AFTER)"
      continue
    fi
    if [[ -n "$LIMIT" && "$attempted" -ge "$LIMIT" ]]; then
      skipped_summary="$skipped_summary
- #$num: out of scope this run (--limit $LIMIT reached)"
      continue
    fi

    if [[ "$TASK_SOURCE" == github || "$TASK_SOURCE" == linear ]]; then
      local existing_pr
      if ! existing_pr="$(find_task_pr "$repo_path" "$num")"; then
        echo "warn: can't list PRs, skipping task #$num rather than risk a duplicate"
        skipped_summary="$skipped_summary
- #$num: not attempted, couldn't list PRs to check for an existing one"
        continue
      fi
      if [[ -n "$existing_pr" ]]; then
        echo "skip: task #$num already has a PR ($existing_pr)"
        pr_skipped=$((pr_skipped+1))
        continue
      fi
    fi

    local -a orphans=()
    mapfile -t orphans < <(find_orphan_branches "$repo_path" "$num")
    local retried=""
    if [[ ${#orphans[@]} -gt 0 ]]; then
      retried="$(discard_orphan_branches "$repo_path" "$branch" "${orphans[@]}")"
      [[ -n "$retried" ]] && echo "retry: task #$num had interrupted attempt(s), discarded: $(printf '%s' "$retried" | tr '
' ' ')"
    fi

    STACK_NOTES_ALL="" STACK_NOTES_REF=""
    if [[ "$stack" != "solo" ]] && ! stack_notes_load "$repo_path" "$stack"; then
      echo "warn: can't read stack '$stack' notes from the tracker, skipping task #$num rather than risk a duplicate notes object"
      skipped_summary="$skipped_summary
- #$num: not attempted, couldn't read stack '$stack' notes from the tracker"
      continue
    fi
    local base_branch; base_branch="$(resolve_base_branch "$repo_path" "$stack" "$branch" stack_branch "$STACK_NOTES_ALL")"
    # The previous task leaves the repo on its own branch; the prompt says the
    # base is "currently checked out", so make that true.
    if ! git -C "$repo_path" checkout --quiet "$base_branch"; then
      echo "warn: can't check out base branch '$base_branch' for task #$num -- skipping it"
      skipped_summary="$skipped_summary
- #$num: not attempted, couldn't check out its base branch '$base_branch'"
      continue
    fi
    # Local notes live on the stack's branches, so re-read them now that the
    # base branch is checked out; tracker notes don't depend on the checkout.
    [[ "$stack" != "solo" && "$TASK_SOURCE" == local ]] && stack_notes_load "$repo_path" "$stack"
    local stack_notes=""
    [[ -n "$STACK_NOTES_ALL" ]] && stack_notes="$(extract_latest_stack_note <<< "$STACK_NOTES_ALL")"

    local task_title
    task_title="$(sed -n '1p' "$blockfile" | sed -E 's/^- \[ \] #[0-9]+ (\[stack: [^]]+\] )?\*\*(.*)\*\*.*$/\2/')"

    local task_prompt
    task_prompt="$(build_task_prompt "$(cat "$blockfile")" "$num" "$stack" "$base_branch" "$stack_notes" "$(printf '%02d' $((attempted+1)))" "$run_num" "$retried" "$STACK_NOTES_REF")"

    # Same r<R>-<PP>-t<NN> as the branch name told to the subprocess, plus a
    # slug derived from the task title.
    local task_slug; task_slug="$(printf '%s' "$task_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//')"
    local base; base="$logdir/r$run_num-$(printf '%02d' $((attempted+1)))-t$num-${task_slug:-task}"
    local errlog="$base.stderr.log"

    echo "--- dispatching task #$num [stack: $stack] ---"
    [[ "$TASK_SOURCE" != linear ]] || ts_linear_move "$LINEAR_LEDGER" "$num" started
    if dispatch "$task_prompt" "$repo_path" "$base.jsonl" "$base.log" "$errlog" "$run_log"; then
      consecutive_failures=0
    else
      consecutive_failures=$((consecutive_failures+1))
      echo "warn: claude exited non-zero for task #$num -- check $errlog"
      if [[ "$consecutive_failures" -ge 2 ]]; then
        echo "error: two consecutive dispatch failures for $name, aborting this repo's run"
        update_stats "$name" "$DISPATCH_TMP_RAW"
        accumulate_session
        record_task_entry "$num" "$task_title" "dispatch-error"
        record_session_totals "$name" "$session_calls" "$session_cost" "$session_duration" "$session_turns" "$session_cache_read" "$session_cache_creation" "$session_input" "$session_output" "$(printf '%s\n' "${session_task_entries[@]}" | jq -s '.')"
        rm -f "$DISPATCH_TMP_RAW"
        [[ -s "$errlog" ]] || rm -f "$errlog"
        rm -rf "$blockdir"
        end_repo
        return 1
      fi
    fi
    update_stats "$name" "$DISPATCH_TMP_RAW"
    accumulate_session

    local task_result; task_result="$(extract_task_result "$DISPATCH_TMP_RAW")"
    rm -f "$DISPATCH_TMP_RAW"
    [[ -s "$errlog" ]] || rm -f "$errlog"

    # Only trust a TASK_RESULT line that names THIS task's own number -- a
    # stale or malformed one (wrong #, or none at all) falls back to the same
    # synthesized "unknown" line extract_task_result's absence would produce.
    local task_result_re; task_result_re="$(ts_task_result_re "$num")"
    if [[ -z "$task_result" || ! "$task_result" =~ $task_result_re ]]; then
      if [[ -n "$task_result" ]]; then
        echo "warn: task #$num's TASK_RESULT line didn't match its own task number, ignoring it: $task_result"
      else
        echo "warn: task #$num did not emit a TASK_RESULT line"
      fi
      task_result="TASK_RESULT: $(ts_task_result_label "$num") status=unknown branch=unknown pr=unknown note=\"subprocess ended without emitting a valid TASK_RESULT line -- check its branch/PR state manually\""
    fi
    run_summary="$run_summary
$task_result"
    # Stacks dispatched this run stay out of the stack-notes sweep's finished set.
    if [[ "$stack" != "solo" && "$ran_keep_args" != *" --keep $stack"* ]]; then
      ran_keep_args="$ran_keep_args --keep $stack"
    fi

    local reported_branch
    reported_branch="$(sed -n "s/^TASK_RESULT: [^ ]* status=[^ ]* branch=\\([^ ]*\\).*/\\1/p" <<< "$task_result")"
    if [[ -n "$reported_branch" && "$reported_branch" != "none" && "$reported_branch" != "unknown" ]]; then
      if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$reported_branch"; then
        stack_branch["$stack"]="$reported_branch"
      else
        echo "warn: task #$num reported branch '$reported_branch', which doesn't exist locally -- stack '$stack' keeps its previous base"
      fi
    fi

    local reported_status
    reported_status="$(sed -n "s/^TASK_RESULT: [^ ]* status=\\([^ ]*\\).*/\\1/p" <<< "$task_result")"
    record_task_entry "$num" "$task_title" "${reported_status:-unknown}"

    attempted=$((attempted+1))
  done

  rm -rf "$blockdir"

  # Tasks skipped for an existing PR still need housekeeping's merged-PR sweep.
  if [[ "$attempted" -eq 0 && "$pr_skipped" -eq 0 ]]; then
    echo "skip: $name (every task filtered out this run, nothing to house-keep)"
    end_repo
    return 0
  fi

  # Remote modes: snapshot every stack's tracker notes for the sweep (task
  # sessions are done, so nothing changes under it).
  local notes_dir=""
  if [[ "$TASK_SOURCE" != local ]]; then
    notes_dir="$(mktemp -d)"
    ts_stack_notes_export "$repo_path" "$notes_dir" || echo "warn: couldn't export tracker stack notes, the sweep will see none"
  fi
  local housekeeping_prompt; housekeeping_prompt="$(build_housekeeping_prompt "$run_summary" "$skipped_summary" "$run_num" "$ran_keep_args" "$notes_dir")"
  echo "--- dispatching housekeeping ---"
  local hk_base="$logdir/r$run_num-housekeeping"
  local errlog="$hk_base.stderr.log"
  dispatch "$housekeeping_prompt" "$repo_path" "$hk_base.jsonl" "$hk_base.log" "$errlog" "$run_log" \
    || echo "warn: claude exited non-zero for $name's housekeeping session -- check $errlog"
  update_stats "$name" "$DISPATCH_TMP_RAW"
  accumulate_session
  rm -f "$DISPATCH_TMP_RAW"
  [[ -z "$notes_dir" ]] || rm -rf "$notes_dir"

  local tasks_json; tasks_json="$(printf '%s\n' "${session_task_entries[@]}" | jq -s '.')"
  record_session_totals "$name" "$session_calls" "$session_cost" "$session_duration" "$session_turns" "$session_cache_read" "$session_cache_creation" "$session_input" "$session_output" "$tasks_json"

  [[ -s "$errlog" ]] || rm -f "$errlog"
  end_repo
}

# bash reads this file as it runs, and dogfooding runs swap overnight.sh under
# us when task branches check out. Exit on the same line as the final block
# closes, so bash never reads past it into whatever the file became.
if [[ -n "$REPO" ]]; then
  TARGET="$REPO"
  # the repo's own folder name (e.g. "nightlight") means this checkout, wherever
  # it lives; the script cd'd to its own dir above, so "." is this repo.
  [[ "$TARGET" != "$(basename "$PWD")" ]] || TARGET="."
  [[ -d "$TARGET" ]] || TARGET="$PROJECT_REPOS_DIR/$REPO"
  run_repo "$TARGET"
else
  [[ -z "$STOP_AFTER$STACK$EXTRA_INSTRUCTIONS$OVERRIDE_PROMPT" ]] || { echo "these run flags require a single target repo (--limit is the exception, it applies per repo)"; exit 1; }
  repo_failures=0
  for d in "$PROJECT_REPOS_DIR"/*/; do
    run_repo "${d%/}" || repo_failures=$((repo_failures+1))
  done
  [[ $repo_failures -eq 0 ]] || echo "warn: $repo_failures repo(s) failed this run"
  (exit $(( repo_failures > 0 )))
fi; exit $?
