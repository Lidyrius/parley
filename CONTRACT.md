# Parley wire contract

Plugin (Claude Code hooks) ⇄ App (`127.0.0.1:8787`). Plain HTTP, JSON.

Terminal-agnostic voice loop (works in Warp, iTerm, tmux, any terminal): the Stop hook
**long-polls** the app and feeds the transcribed reply back into the session via a
`{"decision":"block"}` stop decision — no keystroke/tmux injection.

## `POST /turn`  (long-poll / blocking)
Fired by the **Stop** hook when a turn ends with a `<speak>…</speak>` line. The hook
BLOCKS on this request. The app speaks the line, records the user's voice reply,
transcribes it, and only then responds.

Request:
```json
{
  "event": "turn",
  "session_id": "abc123",
  "cwd": "/Users/sydney/workspace/privat/parley",
  "project": "parley",
  "tmux_pane": "%3",              // "" outside tmux — no longer used for routing
  "speak": "Tests grün. Soll ich das Log-Level senken, Sir?"
}
```
Response (after the user stops talking / silence / timeout):
```json
{ "transcript": "Ja, mach das." }   // "" = user said nothing → end the conversation
```

The hook then, if transcript non-empty, emits on stdout:
```json
{ "decision": "block", "reason": "Ja, mach das.", "systemMessage": "🎙️ Parley: Sprachantwort eingespeist" }
```
which continues the Claude session with the spoken reply as the next turn. Empty
transcript → hook exits 0 → session ends normally.

App-side caps bound the block: ~8 s no-speech timeout, ~20 s max recording, then Groq
STT. The hook allows up to 120 s (`timeout: 130` in hooks.json).

## `POST /ready`
Fired on skill activation to wake + greet. App plays a random pre-cached Jarvis clip.
```json
{ "event": "ready", "session_id": "abc123", "cwd": "…", "project": "parley", "tmux_pane": "%3" }
```

## `GET /health`
`200 {"ok":true}` — used by `greet.sh` to detect/relaunch the app.

## Notes
- Routing/identity is by `session_id` (the hook holds its own blocking connection);
  `tmux_pane` is retained in the payload but no longer drives injection.
- Multiple finished sessions each hold their `/turn` open; the app serializes them
  (speaks one at a time) and answers each hook as its turn completes.
- STT errors or too-short audio → app returns `""` (never an error body), so the
  session ends cleanly instead of injecting garbage.
