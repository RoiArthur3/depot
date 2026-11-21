# depot

## chat.sh — terminal chat with Claude (curl + jq)

A small streaming chat client for the Claude Messages API, written with plain `curl` and `jq`.

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
./chat.sh
```

Type a message and the reply streams in as it is written. `/reset` clears the conversation; `/exit` or Ctrl-D quits.

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_MODEL` | `claude-opus-5-5` | Model id |
| `CLAUDE_EFFORT` | `medium` | `low` / `medium` / `high` / `xhigh` / `max`: how hard Claude thinks before it answers |
| `CLAUDE_SYSTEM` | short assistant prompt | System prompt |
| `SHOW_THINKING` | `0` | `1` streams a dimmed summary of Claude's reasoning |
| `CHAT_HISTORY` | temp file | JSON file holding the conversation; pass the same path again to resume |

Notes:
- The full conversation is resent each turn, including Claude's thinking blocks, unchanged (the API requires this). Automatic prompt caching (`cache_control`) means the repeated history is billed at cache-read rates.
- Server-side refusal fallbacks are on (`fallbacks: "default"`): if a safety classifier declines a request, the API retries it on a fallback model within the same call. If every model declines, the partial reply is discarded and your message is removed so you can rephrase.
- If a request fails, your message is removed from the history so you can send it again.
- Auth: uses `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`, else a profile from `ant auth login`.
