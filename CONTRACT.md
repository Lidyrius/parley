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
  "speak": "Tests grün. Soll ich das Log-Level senken, Sir?",
  "context": "…"                  // optional: the prose before the final tag (no <reply> lines),
                                  // its last 1500 characters — the Überwachungsmodus report carries it
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
  "name": "Literally Apps SEO",             // optional: that one session's own name
  "from": "Zentrale" }                      // optional: who asks — the session reads "[Auftrag von Zentrale] …"
```
→ `{"ok":true,"delivered":"session"|"pending","started":bool}`.
- Without `name`: the folder's running session gets the instruction; none → one is started and
  takes it on its first presence / turn.
- With `name` (no `resume`): the running session **of that name** in the folder gets it; none → a
  **new** session is started beside any running there — only a session that appears after the
  dispatch takes the instruction and the name.
- With `name` and `resume`: that session gets the name (now, or once it shows up).

### Start check: `GET /starting`, `POST /starting/answer` (local, the Zentrale)
After a dispatch starts a session, the host watches its terminal until the session shows up
(macOS: the Terminal tab; Windows can't read another console). A question whose default is No
(`[y/N]`, `(y/N)`, `[y/N/never]`) gets `n` at once. Claude Code's folder-trust dialog doesn't come
up: before every start the host sets `projects[<dir>].hasTrustDialogAccepted` in `~/.claude.json`
(Sir's rule: a folder Parley starts a session in is trusted); should it show anyway (macOS), the
check answers "Yes, I trust this folder". A start still not up after 90 s is handed to the
Zentrale as an instruction with the tab's last lines.
- `GET /starting` → `{"starting":[{"cwd","seconds","screen","readable"}]}` — the starts on the way.
- `POST /starting/answer` `{"cwd","text"}` → types the one-line `text` and Enter into that start's
  tab: `200 {"ok":true}` · `404` no start on the way there · `409` tab gone · `501` Windows.

### Überwachungsmodus: `GET /supervisor`, `POST /supervisor` (local, the Zentrale)
Only the Zentrale talks to Sir. While it is on, a `POST /turn` of any other session is **not
voiced**: the host answers it empty at once (`{"transcript":"","park":true}` — the hook parks and
polls `/wake`; a mod-carried turn just ends, its session is parked by its presence) and hands the
Zentrale a report as an instruction:
```
[Bericht von <label> · Frage an Sir | fertig | arbeitet im Hintergrund weiter] <the spoken line>
Erwartete Antworten: <reply on> · <reply on>            (a <speak> with predicted answers)
Kontext (Auszug aus ihrer letzten Nachricht):           (when the turn carried `context`)
…
(<speak>: Frage oder Rückfrage — die Session wartet geparkt auf Antwort. Session <id>, Ordner <cwd>.)
```
`<speak>` = a question (the session waits for an answer), `<speak-end>` = done. Reports wait in
the host until the Zentrale can take them (reachable, nothing else waiting for it, not talking to
Sir right now), several at once joined by a blank line; none is dropped — a Zentrale that is not
running is started. `after` reminders fire as always. The Zentrale answers a session with
`POST /dispatch` (`resume: <its id>` or `cwd`, plus `from: "Zentrale"`); while the mode is on the
dispatched instruction also says that the answer goes to the Zentrale. "Hey Parley" goes straight
to the Zentrale.
```json
POST /supervisor  { "on": true, "exempt": ["Shirts"] }   // either or both; exempt: names or ids that keep talking to Sir
→ { "ok": true, "on": true, "exempt": ["Shirts"], "zentrale": "<its session id, when it runs>", "waiting": 0 }
```
`GET /supervisor` answers the same. Kept in `supervisor.json` beside `reminders.json` (survives
restarts and updates). `GET /sessions` carries `"supervisor": true` while it is on (omitted
otherwise) and `"zentrale": true` on the Zentrale's row: the apps then show the Zentrale as the
one card and the other sessions (name, state, last line) folded away below it; the Live Activity
shows the Zentrale alone.

### `POST /remind` — `every`
`{"to":"Zentrale","text":"Prüfe Mails, Teams und die Sessions","every":5}` — a Wiedervorlage that
comes again every N minutes (≥ 1) until `POST /remind/cancel`; first after one interval, or at
`at` / `in` when given (never with `after`). It stays in `reminders.json` across restarts; rounds
missed while the host was off or asleep are skipped, not caught up, and a round is skipped while
its session works or talks to Sir. The session reads "Wiedervorlage (alle 5 Minuten): …". Rows of
`GET /remind` and `/sessions` carry `every`.

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
