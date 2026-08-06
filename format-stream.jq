# Formats claude -p --output-format stream-json events into clean,
# human-readable lines for a live terminal. Fed raw NDJSON on stdin.
#
# Stateful: walks the stream via foreach so tool_result lines can be traced
# back to the tool_use that produced them (matched by tool_use_id), which is
# what lets Read results be recognized and skipped below.

def truncate(n):
  if (. | length) > n then .[0:n] + "..." else . end;

def strip_ansi:
  gsub("\\[[0-9;]*[a-zA-Z]"; "");

def tool_summary($name; $input):
  if $name == "Bash" then ($input.command // "" | tostring | strip_ansi | truncate(150))
  else ($input | tostring | strip_ansi | truncate(150))
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
        ($tools[.tool_use_id] // "") as $tool_name |
        if $tool_name == "Read" then
          empty
        else
          (if (.content | type) == "array" then
            (.content | map(.text? // "") | join(" "))
          else
            (.content | tostring)
          end) as $text |
          "    < " + ($text | strip_ansi | truncate(200))
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
        (.; .[$tu.id] = $tu.name)
    else . end;
    format_event($event; .)
  )
