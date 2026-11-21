#!/usr/bin/env bash
# chat.sh - a terminal chat with Claude over the raw Messages API (curl + jq).
#
# Replies stream in as they are written. The whole conversation is resent on
# every turn (the API is stateless), with automatic prompt caching so the
# repeated history bills at cache-read rates.
#
# Requirements: bash, curl, jq (1.6+).
# Auth: ANTHROPIC_API_KEY, or ANTHROPIC_AUTH_TOKEN, or a profile from `ant auth login`.
#
# Settings (environment variables):
#   CLAUDE_MODEL     model id                      (default: claude-opus-5-5)
#   CLAUDE_EFFORT    low|medium|high|xhigh|max     (default: medium)
#   CLAUDE_SYSTEM    system prompt                 (default: a short assistant prompt)
#   SHOW_THINKING=1  stream a summary of Claude's reasoning, dimmed
#   CHAT_HISTORY     JSON file holding the conversation; reuse it to resume a chat
#                    (default: a temporary file deleted on exit)
#
# In the chat: /reset clears the conversation, /exit (or Ctrl-D) quits.

set -uo pipefail

API_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}/v1/messages"
MODEL="${CLAUDE_MODEL:-claude-opus-5-5}"
EFFORT="${CLAUDE_EFFORT:-medium}"
SYSTEM="${CLAUDE_SYSTEM:-You are a helpful, concise assistant chatting in a terminal. Use plain text; avoid heavy Markdown.}"
SHOW_THINKING="${SHOW_THINKING:-0}"

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "error: $bin is required" >&2; exit 1; }
done

# --- authentication --------------------------------------------------------
AUTH_HEADERS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_HEADERS=(-H "x-api-key: $ANTHROPIC_API_KEY")
  BETAS="server-side-fallback-2026-07-01"
else
  token="${ANTHROPIC_AUTH_TOKEN:-}"
  if [[ -z "$token" ]] && command -v ant >/dev/null; then
    token="$(ant auth print-credentials --access-token 2>/dev/null || true)"
  fi
  if [[ -z "$token" ]]; then
    echo "error: set ANTHROPIC_API_KEY (or run \`ant auth login\`)" >&2
    exit 1
  fi
  AUTH_HEADERS=(-H "Authorization: Bearer $token")
  BETAS="server-side-fallback-2026-07-01,oauth-2025-04-20"
fi

# --- conversation state ----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HISTORY="${CHAT_HISTORY:-$WORK/history.json}"
[[ -s "$HISTORY" ]] || echo '[]' > "$HISTORY"
jq -e 'type == "array"' "$HISTORY" >/dev/null 2>&1 || { echo "error: $HISTORY is not a JSON array" >&2; exit 1; }

if [[ "$SHOW_THINKING" == "1" ]]; then DISPLAY_MODE="summarized"; else DISPLAY_MODE="omitted"; fi

# Live renderer: reads raw SSE lines, prints reply text as it arrives.
RENDER='
  select(startswith("data: ")) | .[6:] | fromjson? // empty
  | if .type == "content_block_start" and .content_block.type == "thinking" and $show == "1"
      then "\u001b[2m"
    elif .type == "content_block_stop" and $show == "1"
      then "\u001b[0m"
    elif .type == "content_block_delta" and .delta.type == "text_delta"
      then .delta.text
    elif .type == "content_block_delta" and .delta.type == "thinking_delta" and $show == "1"
      then .delta.thinking
    elif .type == "content_block_start" and .content_block.type == "fallback"
      then "\n\u001b[2m[continued by \(.content_block.to.model // "fallback model")]\u001b[0m\n"
    else empty end'

# Rebuilds the final message from the saved SSE events.
ASSEMBLE='
  [inputs | select(startswith("data: ")) | .[6:] | fromjson? // empty]
  | reduce .[] as $e ({blocks: [], pos: {}, stop: null, model: null, error: null};
      if   $e.type == "message_start" then .model = $e.message.model
      elif $e.type == "content_block_start" then
        .pos[$e.index | tostring] = (.blocks | length) | .blocks += [$e.content_block]
      elif $e.type == "content_block_delta" then
        .pos[$e.index | tostring] as $p
        | if   $e.delta.type == "text_delta"      then .blocks[$p].text += $e.delta.text
          elif $e.delta.type == "thinking_delta"  then .blocks[$p].thinking += $e.delta.thinking
          elif $e.delta.type == "signature_delta" then .blocks[$p].signature = $e.delta.signature
          elif $e.delta.type == "citations_delta" then .blocks[$p].citations += [$e.delta.citation]
          else . end
      elif $e.type == "message_delta" then .stop = ($e.delta.stop_reason // .stop)
      elif $e.type == "error" then .error = $e.error
      else . end)
  # After a mid-output fallback, only text (and the fallback marker itself) may be
  # echoed from before the last fallback block; everything after it echoes normally.
  | .blocks |= (
      ([to_entries[] | select(.value.type == "fallback") | .key] | last) as $last
      | if $last == null then .
        else [to_entries[] | select(.key >= $last or (.value.type | IN("text", "fallback"))) | .value]
        end)'

build_request() {
  jq -n \
    --arg model "$MODEL" --arg effort "$EFFORT" --arg system "$SYSTEM" --arg display "$DISPLAY_MODE" \
    --slurpfile messages "$HISTORY" '{
      model: $model,
      max_tokens: 64000,
      stream: true,
      system: $system,
      thinking: {type: "adaptive", display: $display},
      output_config: {effort: $effort},
      cache_control: {type: "ephemeral"},
      fallbacks: "default",
      messages: $messages[0]
    }'
}

append_message() {  # role, content (JSON)
  jq --arg role "$1" --argjson content "$2" '. + [{role: $role, content: $content}]' \
    "$HISTORY" > "$WORK/h.tmp" && mv "$WORK/h.tmp" "$HISTORY"
}

drop_last_message() {
  jq '.[:-1]' "$HISTORY" > "$WORK/h.tmp" && mv "$WORK/h.tmp" "$HISTORY"
}

send_turn() {
  local raw="$WORK/stream.txt"
  build_request > "$WORK/request.json"

  curl -sS -N "$API_URL" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2026-10-21" \
    -H "anthropic-beta: $BETAS" \
    "${AUTH_HEADERS[@]}" \
    --data-binary "@$WORK/request.json" \
    | tee "$raw" \
    | jq -R -j --unbuffered --arg show "$SHOW_THINKING" "$RENDER"
  local curl_status=${PIPESTATUS[0]}
  printf '\033[0m\n'

  if (( curl_status != 0 )); then
    echo "[network error: curl exited with $curl_status]" >&2
    return 1
  fi

  # A non-streaming JSON body means the request was rejected (4xx/5xx).
  if ! grep -q '^event: message_start' "$raw"; then
    echo "[API error] $(jq -r '.error.message // .' "$raw" 2>/dev/null || cat "$raw")" >&2
    return 1
  fi

  local result
  result="$(jq -R -n "$ASSEMBLE" < "$raw")"

  if [[ "$(jq -r '.error' <<<"$result")" != "null" ]]; then
    echo "[stream error] $(jq -r '.error.type + ": " + .error.message' <<<"$result")" >&2
    return 1
  fi

  case "$(jq -r '.stop' <<<"$result")" in
    refusal)
      echo "[Claude declined this request, and no fallback model could answer it. The partial reply was discarded.]" >&2
      return 1 ;;
    max_tokens)
      echo "[reply hit the max_tokens limit and was cut off]" >&2 ;;
  esac

  append_message assistant "$(jq -c '.blocks' <<<"$result")"
}

# --- main loop -------------------------------------------------------------
echo "Chatting with $MODEL (effort: $EFFORT). /reset clears, /exit quits."
while true; do
  printf '\n\033[1myou>\033[0m '
  IFS= read -r line || { echo; break; }
  case "$line" in
    "") continue ;;
    /exit|/quit) break ;;
    /reset) echo '[]' > "$HISTORY"; echo "[conversation cleared]"; continue ;;
  esac

  append_message user "$(jq -n --arg t "$line" '[{type: "text", text: $t}]')"
  printf '\033[1mclaude>\033[0m '
  # On failure, remove the user turn so history stays valid and you can retry.
  send_turn || drop_last_message
done
