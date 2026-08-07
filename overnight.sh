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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --extra-instructions) EXTRA_INSTRUCTIONS="$2"; shift 2 ;;
    --override-prompt) OVERRIDE_PROMPT="$2"; shift 2 ;;
    --*) echo "unknown flag: $1"; exit 1 ;;
    *) REPO="$1"; shift ;;
  esac
done

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
        echo "$prior_branch"
        return 0
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

# Runs one claude -p subprocess with the given prompt against repo_path,
# streaming it live (through format-stream.jq) and appending it to the run's
# combined raw/readable/stderr logs. Sets DISPATCH_TMP_RAW (a plain, non-local
# assignment -- this is dispatch()'s other return value) to a temp file holding
# just this call's raw NDJSON, so the caller can pull a TASK_RESULT line out of
# exactly this subprocess's output rather than the whole run's; the caller is
# responsible for rm-ing it afterward. Returns claude's own exit status (not
# the trailing tee's) so callers can tell a genuine claude failure (auth error,
# missing format-stream.jq, etc.) apart from a normal run.
dispatch() {
  local prompt="$1" repo_path="$2" raw_log="$3" readable_log="$4" errlog="$5"
  DISPATCH_TMP_RAW="$(mktemp)"

  claude -p "$prompt" \
    --model sonnet \
    --permission-mode acceptEdits \
    --settings .claude/settings.json \
    --add-dir "$repo_path" \
    --output-format stream-json \
    --verbose \
    2>>"$errlog" \
    | tee "$DISPATCH_TMP_RAW" \
    | jq -r -f format-stream.jq \
    | tee -a "$readable_log"
  local claude_status="${PIPESTATUS[0]}"

  cat "$DISPATCH_TMP_RAW" >> "$raw_log"

  # Append genuine tool/harness errors (is_error results - permission denials,
  # bad exit codes, missing files) from just this call to the shared errlog.
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
# means individual claude -p calls, not runs of overnight.sh.
update_stats() {
  local name="$1" raw_log="$2"
  mkdir -p stats
  local stats_file="stats/$name.json"
  local result_line; result_line="$(jq -c 'select(.type == "result")' "$raw_log" | tail -n1)"
  if [[ -z "$result_line" ]]; then
    echo "warn: no result event in $raw_log, skipping stats update"
    return 0
  fi
  local prev_json="{}"
  [[ -f "$stats_file" ]] && prev_json="$(cat "$stats_file")"
  jq -n \
    --argjson prev "$prev_json" \
    --argjson result "$result_line" \
    --arg date "$(date +%F)" \
    '{
      sessions: (($prev.sessions // 0) + 1),
      total_cost_usd: (($prev.total_cost_usd // 0) + $result.total_cost_usd),
      total_duration_s: (($prev.total_duration_s // 0) + ($result.duration_ms / 1000 | floor)),
      total_turns: (($prev.total_turns // 0) + $result.num_turns),
      total_cache_read_tokens: (($prev.total_cache_read_tokens // 0) + ($result.usage.cache_read_input_tokens // 0)),
      total_cache_creation_tokens: (($prev.total_cache_creation_tokens // 0) + ($result.usage.cache_creation_input_tokens // 0)),
      lastRun: {
        date: $date,
        cost_usd: $result.total_cost_usd,
        duration_s: ($result.duration_ms / 1000 | floor),
        num_turns: $result.num_turns,
        cache_read_tokens: ($result.usage.cache_read_input_tokens // 0),
        cache_creation_tokens: ($result.usage.cache_creation_input_tokens // 0)
      }
    }' > "$stats_file"
}

run_repo() {
  local repo_path="$1"
  local name; name="$(basename "$repo_path")"
  local tasks="$repo_path/TASKS.md"

  [[ -f "$tasks" ]] || { echo "skip: $name (no TASKS.md)"; return 0; }
  grep -Eq '^\s*- \[ \]' "$tasks" || { echo "skip: $name (no open tasks)"; return 0; }

  echo "=== $name ==="
  local branch; branch="$(default_branch "$repo_path")" || return 1
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
    [[ -s "$errlog" ]] || rm -f "$errlog"
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
    return 0
  fi

  local -A stack_branch=()
  local attempted=0 consecutive_failures=0
  local run_summary="" skipped_summary=""

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
        rm -f "$DISPATCH_TMP_RAW"
        rm -rf "$blockdir"
        return 1
      fi
    fi
    update_stats "$name" "$DISPATCH_TMP_RAW"

    local task_result; task_result="$(extract_task_result "$DISPATCH_TMP_RAW")"
    rm -f "$DISPATCH_TMP_RAW"

    if [[ -z "$task_result" ]]; then
      echo "warn: task #$num did not emit a TASK_RESULT line"
      task_result="TASK_RESULT: #$num status=unknown branch=unknown pr=unknown note=\"subprocess ended without emitting a TASK_RESULT line -- check its branch/PR state manually\""
    fi
    run_summary="$run_summary
$task_result"

    local reported_branch
    reported_branch="$(sed -n 's/^TASK_RESULT: #[0-9]* status=[^ ]* branch=\([^ ]*\).*/\1/p' <<< "$task_result")"
    if [[ -n "$reported_branch" && "$reported_branch" != "none" && "$reported_branch" != "unknown" ]]; then
      if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$reported_branch"; then
        stack_branch["$stack"]="$reported_branch"
      else
        echo "warn: task #$num reported branch '$reported_branch', which doesn't exist locally -- stack '$stack' keeps its previous base"
      fi
    fi

    attempted=$((attempted+1))
  done

  rm -rf "$blockdir"

  if [[ "$attempted" -eq 0 ]]; then
    echo "skip: $name (every task filtered out this run, nothing to house-keep)"
    return 0
  fi

  local housekeeping_prompt; housekeeping_prompt="$(build_housekeeping_prompt "$run_summary" "$skipped_summary")"
  echo "--- dispatching housekeeping ---"
  dispatch "$housekeeping_prompt" "$repo_path" "$raw_log" "$readable_log" "$errlog" \
    || echo "warn: claude exited non-zero for $name's housekeeping session -- check $errlog"
  update_stats "$name" "$DISPATCH_TMP_RAW"
  rm -f "$DISPATCH_TMP_RAW"

  [[ -s "$errlog" ]] || rm -f "$errlog"
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
