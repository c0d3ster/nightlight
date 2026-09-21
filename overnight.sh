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
# docs/stack-notes/<stack>.md in the target repo, not a raw diff/commit dump.
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

# Splits $1 (TASKS.md)'s Agent-Ready/Verify/Research task blocks into one file
# per task under $2 (clearing anything already there), and prints one line per
# task to stdout: "<number>\t<effective-stack>\t<blockfile>", in file order.
# Effective stack is the task's own [stack: x] tag, or -- per the
# stack-by-default rule in CLAUDE.md -- whichever task before it in file order
# had one, computed here so callers don't have to re-derive inheritance once
# --stack/--stop-after/--limit filter the list down.
split_tasks() {
  local tasks_file="$1" outdir="$2"
  mkdir -p "$outdir"
  rm -f "$outdir"/*.task

  local heading_re='^## '
  local target_heading_re='^## (Agent-Ready|Verify|Research)'
  local task_re='^- \[ \] #([0-9]+)(.*)$'
  local stack_re='\[stack: ([A-Za-z0-9_-]+)\]'

  local in_target=0 prev_stack="" idx=0
  local cur_file="" cur_num="" cur_stack=""
  local -a index=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $heading_re ]]; then
      [[ -n "$cur_file" ]] && index+=("$cur_num"$'\t'"$cur_stack"$'\t'"$cur_file")
      cur_file=""
      if [[ "$line" =~ $target_heading_re ]]; then in_target=1; else in_target=0; fi
      continue
    fi
    if [[ $in_target -eq 1 && "$line" =~ $task_re ]]; then
      [[ -n "$cur_file" ]] && index+=("$cur_num"$'\t'"$cur_stack"$'\t'"$cur_file")
      idx=$((idx+1))
      cur_num="${BASH_REMATCH[1]}"
      local rest="${BASH_REMATCH[2]}"
      if [[ "$rest" =~ $stack_re ]]; then cur_stack="${BASH_REMATCH[1]}"; else cur_stack="${prev_stack:-solo}"; fi
      prev_stack="$cur_stack"
      cur_file="$outdir/$(printf '%04d' "$idx")-$cur_num.task"
      printf '%s\n' "$line" > "$cur_file"
      continue
    fi
    if [[ $in_target -eq 1 && -n "$cur_file" ]]; then
      printf '%s\n' "$line" >> "$cur_file"
    fi
  done < "$tasks_file"
  [[ -n "$cur_file" ]] && index+=("$cur_num"$'\t'"$cur_stack"$'\t'"$cur_file")

  local rec
  for rec in "${index[@]}"; do
    printf '%s\n' "$rec"
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

  local notes_file="$repo_path/docs/stack-notes/$stack.md"
  if [[ -f "$notes_file" ]]; then
    local prior_branch
    prior_branch="$(grep '^Branch: ' "$notes_file" | tail -n1 | sed 's/^Branch: //')"
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

# Builds the prompt for a single task's fresh subprocess: the task text
# verbatim, stack/stack-notes context (or the solo/no-stack-notes rule), any
# --extra-instructions, and the TASK_RESULT contract housekeeping consumes.
build_task_prompt() {
  local task_text="$1" num="$2" stack="$3" base_branch="$4" stack_notes="$5"

  local p="A target repo has been added to this session via --add-dir. This is exactly ONE task from that repo's TASKS.md, dispatched by nightlight's overnight runner as its own fresh session -- you have no memory of any other task, past or future, in this run. Implement it per the \"Overnight Agent Workflow\" rules in the CLAUDE.md of THIS repo (nightlight, the one this session was launched from) -- branching, quality gates, PR, and NEEDS HUMAN/blocked handling all still apply exactly as documented there. Work this ONE task only, then stop: do not open, read for other purposes, or act on any other TASKS.md item, and do not perform end-of-session housekeeping -- a separate session handles that once, after every task dispatched this run is done.

Here is the task, verbatim from TASKS.md:

$task_text"

  if [[ "$stack" == "solo" ]]; then
    p="$p

This task is [stack: solo]: branch from the repo's default branch (currently checked out, at \"$base_branch\"), independent of every other task. Do not create or touch any docs/stack-notes/ file."
  elif [[ -n "$stack_notes" ]]; then
    p="$p

This task continues stack \"$stack\". Branch your work from \"$base_branch\" (the latest branch already in this stack) instead of the repo's default branch. Below is docs/stack-notes/$stack.md, written by earlier tasks in this same stack -- use it as your context instead of inspecting their full diffs or commit history:

---
$stack_notes
---

Before finishing, append your own entry to docs/stack-notes/$stack.md (never rewrite earlier entries) in the same format used above: a heading with this task's number and title, a \"Branch: <your-branch-name>\" line, key decisions, interfaces/exports created, and any deviation from acceptance criteria. Commit it as part of this task's own work, on this task's own branch."
  else
    p="$p

This task starts stack \"$stack\". Branch from the repo's default branch (currently checked out, at \"$base_branch\"). Before finishing, create docs/stack-notes/$stack.md with your own entry: a heading with this task's number and title, a \"Branch: <your-branch-name>\" line, key decisions, interfaces/exports created, and any deviation from acceptance criteria -- later tasks in this stack will read this file instead of your diff or commit history. Commit it as part of this task's own work, on this task's own branch."
  fi

  if [[ -n "$EXTRA_INSTRUCTIONS" ]]; then
    p="$p

IMPORTANT - special instructions for this run: $EXTRA_INSTRUCTIONS"
  fi

  p="$p

When you are done -- whether the task completed, needs a human step, or is blocked -- end your FINAL message with exactly one line, on its own, after everything else, nothing after it:
TASK_RESULT: #$num status=<done|blocked|needs-human> branch=<branch-name-or-none> pr=<number-or-none> note=\"<one-line summary>\"
Use status=done when the PR is open and every acceptance criterion is met; status=needs-human when the PR is open but a manual step remains (put the exact steps in the PR description and TASKS.md per CLAUDE.md, keep note to a short pointer); status=blocked when you stopped before opening a PR (note explains why, per CLAUDE.md's blocked rules). This line is machine-parsed by this run's housekeeping session afterward -- match the format exactly, no markdown, no extra lines around it."

  printf '%s' "$p"
}

# Builds the prompt for the single end-of-run housekeeping subprocess: every
# dispatched task's TASK_RESULT line (collected by the caller across the
# loop), plus which tasks were filtered out and left untouched this run.
build_housekeeping_prompt() {
  local run_summary="$1" skipped_summary="$2"
  local p="A target repo has been added to this session via --add-dir. This session runs ONLY the end-of-session housekeeping step from the \"Overnight Agent Workflow\" rules in CLAUDE.md (this repo, nightlight's own) -- this run just finished dispatching one fresh session per task, so you were not present for any of them. Do not attempt any task work yourself.

Here is what each dispatched task's own session reported when it finished, verbatim (one TASK_RESULT line per task attempted this run):
${run_summary:-"(no tasks were attempted this run)"}"

  if [[ -n "$skipped_summary" ]]; then
    p="$p

Tasks NOT attempted this run (filtered out by --stack/--stop-after/--limit) -- leave these exactly as-is in TASKS.md, they are neither done nor blocked, just out of scope this run:
$skipped_summary"
  fi

  p="$p

Treat the TASK_RESULT lines above as a starting point, not ground truth -- a task session can misreport, so confirm each PR/branch's actual state with git/gh before writing anything (e.g. gh pr view <pr> --json state,mergedAt, or gh pr list --head <branch>). Then follow the \"TASKS.md maintenance\" rules in CLAUDE.md exactly: check off or annotate each attempted task (NEEDS HUMAN / blocked as reported, with the note given), archive completed tasks to a new docs/tasks-archive/<date>.md, update tasksCompleted/tasksBlocked in docs/nightlight-meta.json, and open the housekeeping PR targeting main."

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
  local prompt="$1" repo_path="$2" raw_log="$3" readable_log="$4" errlog="$5"
  local pause_retries=0 claude_status=0

  while true; do
    DISPATCH_TMP_RAW="$(mktemp)"

    # --add-dir before -p: keeps the repo path ahead of the much larger
    # prompt, in case anything ever truncates the command line (not observed
    # in testing, but free to guard against).
    claude \
      --add-dir "$repo_path" \
      --model sonnet \
      --permission-mode acceptEdits \
      --settings .claude/settings.json \
      --output-format stream-json \
      --verbose \
      -p "$prompt" \
      2>>"$errlog" \
      | tee "$DISPATCH_TMP_RAW" \
      | jq -r -f format-stream.jq \
      | tee -a "$readable_log"
    claude_status="${PIPESTATUS[0]}"

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
# US_COST/US_DURATION_S/US_TURNS/US_CACHE_READ/US_CACHE_CREATION (plain,
# non-local -- this function's return values) to this call's own numbers,
# zeroed if the result event was missing, for run_repo() to roll into a
# whole-run total.
update_stats() {
  local name="$1" raw_log="$2"
  mkdir -p stats
  local stats_file="stats/$name.json"
  local result_line; result_line="$(jq -c 'select(.type == "result")' "$raw_log" | tail -n1)"
  US_COST=0; US_DURATION_S=0; US_TURNS=0; US_CACHE_READ=0; US_CACHE_CREATION=0
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
      total_cache_creation_tokens: (($prev.total_cache_creation_tokens // 0) + ($result.usage.cache_creation_input_tokens // 0))
    }' > "$stats_file"

  US_COST="$(jq -n --argjson r "$result_line" '$r.total_cost_usd')"
  US_DURATION_S="$(jq -n --argjson r "$result_line" '$r.duration_ms / 1000 | floor')"
  US_TURNS="$(jq -n --argjson r "$result_line" '$r.num_turns')"
  US_CACHE_READ="$(jq -n --argjson r "$result_line" '$r.usage.cache_read_input_tokens // 0')"
  US_CACHE_CREATION="$(jq -n --argjson r "$result_line" '$r.usage.cache_creation_input_tokens // 0')"
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
        check(($e.value.taskNumber | type) == "number"; "lastSession.tasks[\($e.key)].taskNumber missing or not a number"),
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
  local name="$1" calls="$2" cost="$3" duration_s="$4" turns="$5" cache_read="$6" cache_creation="$7" tasks_json="${8:-[]}"
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
    --argjson tasks "$tasks_json" \
    '{
      date: $date,
      calls: $calls,
      cost_usd: $cost,
      duration_s: $duration_s,
      num_turns: $turns,
      cache_read_tokens: $cache_read,
      cache_creation_tokens: $cache_creation,
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

run_repo() {
  local repo_path="$1"
  local name; name="$(basename "$repo_path")"
  local tasks="$repo_path/TASKS.md"

  [[ -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; return 0; }
  grep -Eq '^\s*- \[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; return 0; }

  acquire_lock "$repo_path" "$name" || return 1
  ACTIVE_REPO_PATH="$repo_path"

  echo "=== $name ==="
  local branch; branch="$(default_branch "$repo_path")" || { end_repo; return 1; }
  git -C "$repo_path" checkout "$branch" && git -C "$repo_path" pull

  mkdir -p logs
  local raw_log="logs/$name-$(date +%F).jsonl"
  local readable_log="logs/$name-$(date +%F).log"
  local errlog="logs/$name-$(date +%F).stderr.log"

  if [[ -n "$OVERRIDE_PROMPT" ]]; then
    dispatch "$OVERRIDE_PROMPT" "$repo_path" "$raw_log" "$readable_log" "$errlog" \
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
  done < <(split_tasks "$tasks" "$blockdir")

  if [[ ${#task_records[@]} -eq 0 ]]; then
    echo "skip: $name (no tasks found in Agent-Ready/Verify/Research)"
    rm -rf "$blockdir"
    end_repo
    return 0
  fi

  local -A stack_branch=()
  local attempted=0 consecutive_failures=0
  local run_summary="" skipped_summary=""
  local session_calls=0 session_cost=0 session_duration=0 session_turns=0 session_cache_read=0 session_cache_creation=0

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
  }

  # Appends one task's numbers (from the US_* just set by update_stats()) as
  # an entry in this run's tasks array. Only the per-task dispatch loop below
  # calls this -- housekeeping isn't a numbered task.
  local -a session_task_entries=()
  record_task_entry() {
    local num="$1" title="$2" status="$3"
    session_task_entries+=("$(jq -nc \
      --argjson num "$num" \
      --arg title "$title" \
      --arg status "$status" \
      --argjson cost "$US_COST" \
      --argjson duration_s "$US_DURATION_S" \
      --argjson turns "$US_TURNS" \
      --argjson cache_read "$US_CACHE_READ" \
      --argjson cache_creation "$US_CACHE_CREATION" \
      '{taskNumber: $num, taskTitle: $title, status: $status, cost_usd: $cost, duration_s: $duration_s, num_turns: $turns, cache_read_tokens: $cache_read, cache_creation_tokens: $cache_creation}')")
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

    local base_branch; base_branch="$(resolve_base_branch "$repo_path" "$stack" "$branch" stack_branch)"
    local stack_notes=""
    if [[ "$stack" != "solo" && -f "$repo_path/docs/stack-notes/$stack.md" ]]; then
      stack_notes="$(cat "$repo_path/docs/stack-notes/$stack.md")"
    fi

    local task_title
    task_title="$(sed -n '1p' "$blockfile" | sed -E 's/^- \[ \] #[0-9]+ (\[stack: [^]]+\] )?\*\*(.*)\*\*.*$/\2/')"

    local task_prompt
    task_prompt="$(build_task_prompt "$(cat "$blockfile")" "$num" "$stack" "$base_branch" "$stack_notes")"

    echo "--- dispatching task #$num [stack: $stack] ---"
    if dispatch "$task_prompt" "$repo_path" "$raw_log" "$readable_log" "$errlog"; then
      consecutive_failures=0
    else
      consecutive_failures=$((consecutive_failures+1))
      echo "warn: claude exited non-zero for task #$num -- check $errlog"
      if [[ "$consecutive_failures" -ge 2 ]]; then
        echo "error: two consecutive dispatch failures for $name, aborting this repo's run"
        update_stats "$name" "$DISPATCH_TMP_RAW"
        accumulate_session
        record_task_entry "$num" "$task_title" "dispatch-error"
        record_session_totals "$name" "$session_calls" "$session_cost" "$session_duration" "$session_turns" "$session_cache_read" "$session_cache_creation" "$(printf '%s\n' "${session_task_entries[@]}" | jq -s '.')"
        rm -f "$DISPATCH_TMP_RAW"
        rm -rf "$blockdir"
        end_repo
        return 1
      fi
    fi
    update_stats "$name" "$DISPATCH_TMP_RAW"
    accumulate_session

    local task_result; task_result="$(extract_task_result "$DISPATCH_TMP_RAW")"
    rm -f "$DISPATCH_TMP_RAW"

    # Only trust a TASK_RESULT line that names THIS task's own number -- a
    # stale or malformed one (wrong #, or none at all) falls back to the same
    # synthesized "unknown" line extract_task_result's absence would produce.
    local task_result_re="^TASK_RESULT: #$num "
    if [[ -z "$task_result" || ! "$task_result" =~ $task_result_re ]]; then
      if [[ -n "$task_result" ]]; then
        echo "warn: task #$num's TASK_RESULT line didn't match its own task number, ignoring it: $task_result"
      else
        echo "warn: task #$num did not emit a TASK_RESULT line"
      fi
      task_result="TASK_RESULT: #$num status=unknown branch=unknown pr=unknown note=\"subprocess ended without emitting a valid TASK_RESULT line -- check its branch/PR state manually\""
    fi
    run_summary="$run_summary
$task_result"

    local reported_branch
    reported_branch="$(sed -n "s/^TASK_RESULT: #$num status=[^ ]* branch=\\([^ ]*\\).*/\\1/p" <<< "$task_result")"
    if [[ -n "$reported_branch" && "$reported_branch" != "none" && "$reported_branch" != "unknown" ]]; then
      if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$reported_branch"; then
        stack_branch["$stack"]="$reported_branch"
      else
        echo "warn: task #$num reported branch '$reported_branch', which doesn't exist locally -- stack '$stack' keeps its previous base"
      fi
    fi

    local reported_status
    reported_status="$(sed -n "s/^TASK_RESULT: #$num status=\\([^ ]*\\).*/\\1/p" <<< "$task_result")"
    record_task_entry "$num" "$task_title" "${reported_status:-unknown}"

    attempted=$((attempted+1))
  done

  rm -rf "$blockdir"

  if [[ "$attempted" -eq 0 ]]; then
    echo "skip: $name (every task filtered out this run, nothing to house-keep)"
    end_repo
    return 0
  fi

  local housekeeping_prompt; housekeeping_prompt="$(build_housekeeping_prompt "$run_summary" "$skipped_summary")"
  echo "--- dispatching housekeeping ---"
  dispatch "$housekeeping_prompt" "$repo_path" "$raw_log" "$readable_log" "$errlog" \
    || echo "warn: claude exited non-zero for $name's housekeeping session -- check $errlog"
  update_stats "$name" "$DISPATCH_TMP_RAW"
  accumulate_session
  rm -f "$DISPATCH_TMP_RAW"

  local tasks_json; tasks_json="$(printf '%s\n' "${session_task_entries[@]}" | jq -s '.')"
  record_session_totals "$name" "$session_calls" "$session_cost" "$session_duration" "$session_turns" "$session_cache_read" "$session_cache_creation" "$tasks_json"

  [[ -s "$errlog" ]] || rm -f "$errlog"
  end_repo
}

if [[ -n "$REPO" ]]; then
  TARGET="$REPO"
  [[ -d "$TARGET" ]] || TARGET="$PROJECT_REPOS_DIR/$REPO"
  run_repo "$TARGET"
else
  [[ -z "$STOP_AFTER$STACK$EXTRA_INSTRUCTIONS$OVERRIDE_PROMPT" ]] || { echo "these run flags require a single target repo (--limit is the exception, it applies per repo)"; exit 1; }
  for d in "$PROJECT_REPOS_DIR"/*/; do
    run_repo "${d%/}"
  done
fi
