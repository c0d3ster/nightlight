# Formats claude -p --output-format stream-json events into clean,
# human-readable lines for a live terminal. Fed raw NDJSON on stdin.
#
# Stateful: walks the stream via foreach so tool_result lines can be traced
# back to the tool_use that produced them (matched by tool_use_id), which is
# what lets Read/Glob/Grep/Bash results be recognized and condensed below.

def truncate(n):
  if (. | length) > n then .[0:n] + "..." else . end;

def strip_ansi:
  gsub("\\[[0-9;]*[a-zA-Z]"; "");

def strip_cr:
  gsub("\r"; "");

def non_empty_lines:
  split("\n") | map(select(length > 0));

# aligns continuation lines under the "    < " prefix (6 chars) so multi-line
# results read as one indented block instead of falling back to column 0.
def indent_continuations:
  gsub("\n"; "\n      ");

def tool_summary($name; $input):
  if $name == "Bash" then ($input.command // "" | tostring | strip_ansi | truncate(150))
  else ($input | tostring | strip_ansi | truncate(150))
  end;

# vitest: pull the "Test Files"/"Tests" summary lines plus each FAIL entry,
# regardless of where they land in the (already tail-truncated) output.
def summarize_vitest:
  (split("\n")) as $lines |
  ($lines | map(select(test("^\\s*(Test Files|Tests)\\s")))) as $summary_lines |
  ($lines
    | map(select(test("^\\s*FAIL\\s+\\S+\\s+")))
    | map(capture("^\\s*FAIL\\s+\\S+\\s+(?<rest>.+)$").rest)
  ) as $failed |
  ($summary_lines | join("\n")) as $summary |
  if ($failed | length) > 0 then
    $summary + "\n" + ($failed | map("  FAILED " + .) | join("\n"))
  else
    $summary
  end;

# tsc: each "<file>:<line>:<col> - error TSxxxx: ..." line plus the closing
# "Found N errors in M files." line.
def summarize_tsc:
  (split("\n")) as $lines |
  ($lines | map(select(test("^\\S+\\.tsx?:[0-9]+:[0-9]+ - error TS")))) as $errors |
  ($lines | map(select(test("^Found [0-9]+ errors? in"))) | first) as $found_line |
  ($errors | map("  " + .) | join("\n")) as $body |
  if $found_line then $found_line + "\n" + $body else $body end;

# eslint (stylish formatter): each file header groups its own indented
# "<line>:<col>  error|warning  message  rule" lines; track the current file
# as we walk so each problem line can be reattached to it.
def summarize_eslint:
  (split("\n")) as $lines |
  (reduce $lines[] as $line
    ({file: null, out: []};
      if ($line | test("^\\S.*\\.(ts|tsx|js|jsx|mjs|cjs)$")) then
        {file: $line, out: .out}
      elif ($line | test("^\\s+[0-9]+:[0-9]+\\s+(error|warning)\\s")) then
        .out += [(.file // "?") + "  " + ($line | ltrimstr(" "))]
      else
        .
      end)
  ) as $acc |
  ($lines | map(select(test("^✖ [0-9]+ problems? \\("))) | first) as $summary_line |
  ($acc.out | map("  " + .) | join("\n")) as $body |
  if $summary_line then $summary_line + "\n" + $body else $body end;

# true for a Bash command that's purely dumping/listing file contents -
# chains of cat/ls/echo/head/tail joined by "&&"/";"/"||" (optionally behind
# "cd ... &&", "2>/dev/null" fallbacks, and "| head -N"/"| tail -N" trims).
# Same noise-vs-signal tradeoff as the Read tool suppression above: the
# request line already shows what was inspected, so the dump adds nothing.
def is_pure_inspect($cmd):
  ($cmd | sub("^cd\\s+\"[^\"]*\"\\s*&&\\s*"; "")) as $rest |
  ([$rest | splits("\\s*(&&|\\|\\||;)\\s*")]) as $parts |
  ($parts | length) > 0 and
  ($parts | all(
    test("^(cat|ls|echo|head|tail|find)\\b[^|<>]*(\\s+2>\\s*(/dev/null|&1))?(\\s*\\|\\s*(head|tail)\\b[^|<>]*)?$")
    or
    test("^(tasklist|ps)\\b[^|<>]*(\\s+2>\\s*(/dev/null|&1))?(\\s*\\|\\s*grep\\b[^|<>]*)?$")
  ));

def summarize_bash:
  . as $text |
  if ($text | test(" Test Files ")) then summarize_vitest
  elif ($text | test("error TS[0-9]+:")) then summarize_tsc
  elif ($text | test("✖ [0-9]+ problems? \\(")) then summarize_eslint
  else
    (non_empty_lines) as $lines |
    ($lines | map(select(test("^\\[[A-Z]+\\]"))) | length) as $tagged |
    if $tagged >= 2 and
       ($lines[-1] | test("success|complete|done|failed|error"; "i") or test("[✅❌]")) then
      $lines[-1]
    else
      ($lines | if length > 5 then .[-5:] else . end | join("\n") | truncate(300))
    end
  end;

# recognizes a Bash-invoked "grep <pattern> ..." (optionally behind "cd ...
# &&" and a trailing "| head/tail -N"); returns the pattern so it gets the
# same one-line match-count summary as the dedicated Grep tool, instead of
# dumping every matched line.
def bash_grep_pattern($cmd):
  ($cmd | sub("^cd\\s+\"[^\"]*\"\\s*&&\\s*"; "")) as $rest |
  ($rest | sub("\\s*\\|\\s*(head|tail)\\b.*$"; "")) as $core |
  if ($core | test("^grep\\s")) then
    ($core | capture("^grep\\s+(-[a-zA-Z]+\\s+)*\"(?<pat>[^\"]*)\"").pat // null)
  else
    null
  end;

def tool_result_text($content):
  if ($content | type) == "array" then
    ($content | map(.text? // "") | join(" "))
  else
    ($content | tostring)
  end;

def format_event($event; $tools):
  if $event.type == "system" and $event.subtype == "init" then
    "=== session started (model: \($event.model)) ==="
  elif $event.type == "assistant" then
    ($event.message.content[]? |
      if .type == "text" then
        .text
      elif .type == "tool_use" then
        "  > " + .name + "(" + tool_summary(.name; .input) + ")"
      else empty
      end)
  elif $event.type == "user" then
    ($event.message.content[]? |
      if .type == "tool_result" then
        ($tools[.tool_use_id] // {}) as $tool |
        ($tool.name // "") as $tool_name |
        (tool_result_text(.content) | strip_ansi | strip_cr) as $text |
        if $tool_name == "Read" then
          empty
        elif $tool_name == "Glob" then
          ($text | non_empty_lines | length) as $n |
          "    < found " + ($n | tostring) +
            (if $n == 1 then " file matching \"" else " files matching \"" end) +
            ($tool.input.pattern // "?") + "\""
        elif $tool_name == "Grep" then
          ($text | non_empty_lines | length) as $n |
          ($tool.input.output_mode == "files_with_matches") as $is_files |
          "    < " + ($n | tostring) +
            (if $is_files then (if $n == 1 then " file" else " files" end)
             else (if $n == 1 then " match" else " matches" end) end) +
            " for \"" + ($tool.input.pattern // "?") + "\""
        elif $tool_name == "Bash" and is_pure_inspect($tool.input.command // "") then
          empty
        elif $tool_name == "Bash" then
          (bash_grep_pattern($tool.input.command // "")) as $grep_pat |
          if $grep_pat then
            ($text | non_empty_lines | length) as $n |
            "    < " + ($n | tostring) + (if $n == 1 then " match" else " matches" end) +
              " for \"" + $grep_pat + "\""
          else
            "    < " + ($text | summarize_bash | indent_continuations)
          end
        else
          "    < " + ($text | truncate(200) | indent_continuations)
        end
      else empty
      end)
  elif $event.type == "result" then
    "=== session done: \($event.subtype) | $\(($event.total_cost_usd * 10000 | round) / 10000) | \(($event.duration_ms / 1000) | floor)s | \($event.num_turns) turns ==="
  else
    empty
  end;

foreach (., inputs) as $event
  ( {};
    if $event.type == "assistant" then
      reduce ($event.message.content[]? | select(.type == "tool_use")) as $tu
        (.; .[$tu.id] = {name: $tu.name, input: $tu.input})
    else . end;
    format_event($event; .)
  )
