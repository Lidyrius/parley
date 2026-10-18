# Parley wire contract

Plugin (Claude Code/Codex hooks) ⇄ App (`127.0.0.1:8787`). Plain HTTP, JSON.

Terminal-agnostic voice loop (works in Warp, iTerm, tmux, any terminal): the Stop hook
**long-polls** the app and feeds the transcribed reply back into the session via a
the host's stop decision — no keystroke/tmux injection. Claude Code and Codex share the
same `/turn` contract; Codex receives valid JSON on every Stop-hook invocation.

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
which continues the host session with the spoken reply as the next turn. Empty
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

## Session labels
A session's spoken label comes from `.parley.json` (`name`) in its folder, else the folder name —
so every session of a folder shares it. One session can have **its own name** instead (it wins over
the label the hook / mod report, everywhere: `/sessions` `label`, the app, the iPhone, the
announcement "Update zu …", and the `label` of its queued turn). Names survive app restarts.

### `POST /dispatch` (local, the Zentrale)
```json
{ "cwd": "/abs/path", "instruction": "…", "start": true,
  "resume": "<past session id>",            // optional: continue that session (cwd defaults to its own)
  "name": "Literally Apps SEO" }            // optional: that one session's own name
```
→ `{"ok":true,"delivered":"session"|"pending","started":bool}`.
- Without `name`: the folder's running session gets the instruction; none → one is started and
  takes it on its first presence / turn.
- With `name` (no `resume`): the running session **of that name** in the folder gets it; none → a
  **new** session is started beside any running there — only a session that appears after the
  dispatch takes the instruction and the name.
- With `name` and `resume`: that session gets the name (now, or once it shows up).

### `POST /rename`
```json
{ "id": "<session id>", "name": "Literally Apps SEO" }   // "" or null → back to the project's label
```
→ `200 {"ok":true,"id":…,"label":…}` · `404` unknown session · `400` no id.

## Notes
- Routing/identity is by `session_id` (the hook holds its own blocking connection);
  `tmux_pane` is retained in the payload but no longer drives injection.
- Multiple finished sessions each hold their `/turn` open; the app serializes them
  (speaks one at a time) and answers each hook as its turn completes.
- STT errors or too-short audio → app returns `""` (never an error body), so the
  session ends cleanly instead of injecting garbage.
