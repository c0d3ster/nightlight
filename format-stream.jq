# Formats claude -p --output-format stream-json events into clean,
# human-readable lines for a live terminal. Fed raw NDJSON on stdin.

def truncate(n):
  if (. | length) > n then .[0:n] + "..." else . end;

def tool_summary:
  if .name == "Bash" then (.input.command // "" | tostring | truncate(150))
  else (.input | tostring | truncate(150))
  end;

if .type == "system" and .subtype == "init" then
  "=== session started (model: \(.model)) ==="
elif .type == "assistant" then
  (.message.content[]? |
    if .type == "text" then
      .text
    elif .type == "tool_use" then
      "  > " + .name + "(" + tool_summary + ")"
    else empty
    end)
elif .type == "user" then
  (.message.content[]? |
    if .type == "tool_result" then
      (if (.content | type) == "array" then
        (.content | map(.text? // "") | join(" "))
      else
        (.content | tostring)
      end) as $text |
      "    < " + ($text | truncate(200))
    else empty
    end)
elif .type == "result" then
  "=== session done: \(.subtype) | $\((.total_cost_usd * 10000 | round) / 10000) | \((.duration_ms / 1000) | floor)s | \(.num_turns) turns ==="
else
  empty
end
