# Vloude wire contract

Plugin (Claude Code hooks) → App (`127.0.0.1:8787`). Plain HTTP POST, JSON body.

## `POST /turn`
Fired by the **Stop** hook when a Claude turn ends and a `<speak>…</speak>` line was emitted.

```json
{
  "event": "turn",
  "session_id": "abc123",
  "cwd": "/Users/sydney/workspace/privat/vloude",
  "project": "vloude",
  "tmux_pane": "%3",
  "speak": "Tests grün, API deployed. Soll ich das Log-Level senken?"
}
```

- `speak` — text between `<speak>` and `</speak>` in the last assistant message. Never empty (hook skips POST if empty).
- `tmux_pane` — value of `$TMUX_PANE` in the hook's shell (empty string if not in tmux → app cannot inject, speaks only).
- `project` — `basename "$cwd"`, used as the spoken/UI label.

App enqueues, speaks, records reply, transcribes, then injects back:
```
tmux send-keys -t "$tmux_pane" -l "<transcript>"   # literal, no interpretation
tmux send-keys -t "$tmux_pane" Enter
```

## `POST /ready`
Fired on skill activation (SessionStart / skill entry) to wake + greet.

```json
{ "event": "ready", "session_id": "abc123", "cwd": "…", "project": "vloude", "tmux_pane": "%3" }
```

App plays a random pre-cached "Ich bin bereit" clip. No reply loop.

## App responses
`200 {"ok":true}` on accept. Hook ignores body (fire-and-forget, short timeout).
If app unreachable, activation hook runs `open -a Vloude` once and retries.
