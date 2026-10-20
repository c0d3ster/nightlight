#!/usr/bin/env bash
# Local task source: tasks live in the target repo's TASKS.md. Sourced by
# overnight.sh's run_repo(); see docs/plans/multi-task-source.md Phase 1.2 for
# the ts_* contract every task-source module implements.

# --stop-after compares ids numerically; local ids are plain integers.
TS_NUMERIC_IDS=1

# Any open dispatchable work? Prints nothing; exit status is the answer.
ts_is_eligible() {
  local repo_path="$1"
  grep -Eq '^\s*- \[ \]' "$repo_path/TASKS.md"
}

# Splits $1 (repo path)'s TASKS.md Agent-Ready/Verify/Research task blocks into one file
# per task under $2 (clearing anything already there), and prints one line per
# task to stdout: "<number>\t<effective-stack>\t<blockfile>", in file order.
# Effective stack is the task's own [stack: x] tag, or -- per the
# stack-by-default rule in CLAUDE.md -- whichever task before it in file order
# had one, computed here so callers don't have to re-derive inheritance once
# --stack/--stop-after/--limit filter the list down.
ts_list_tasks() {
  local tasks_file="$1/TASKS.md" outdir="$2"
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

# How this source writes a task id in the TASK_RESULT line the prompt asks for.
ts_task_result_label() {
  printf '%s' "#$1"
}

# Regex (ERE) matching this task's own TASK_RESULT line, anchored at line start.
ts_task_result_re() {
  local id="$1"
  printf '%s' "^TASK_RESULT: $(ts_task_result_label "$id") "
}

# Open TASKS.md items plus archived tasks whose text matches $2 (case
# insensitive fixed string). Prints "<state>\t<file>:<line>\t<text>", state
# being open or archived.
ts_find_related() {
  local repo_path="$1" query="$2"
  local -a archives=()
  local f
  for f in "$repo_path"/docs/tasks-archive/*.md; do
    [[ -f "$f" ]] && archives+=("$f")
  done
  [[ -f "$repo_path/TASKS.md" ]] && grep -Fin -- "$query" "$repo_path/TASKS.md" \
    | sed -E 's/^([0-9]+):(.*)$/open\tTASKS.md:\1\t\2/'
  [[ ${#archives[@]} -gt 0 ]] && grep -Fin -- "$query" "${archives[@]}" \
    | sed -E 's#^.*/([^/]+\.md):([0-9]+):(.*)$#archived\tdocs/tasks-archive/\1:\2\t\3#'
  return 0
}
