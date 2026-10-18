# Parley for iPhone — plan and relay protocol

Parley on the iPhone: see every Parley session, talk to Parley from anywhere (car via CarPlay,
AirPods), get updates as a real call. The Mac (or Windows) app stays the brain — TTS, STT,
turn queue, sessions. A small relay on Cloudflare connects the two from any network: both
sides dial **out** to it, so the Mac opens no port and the phone needs no VPN.

```
iPhone app ──wss──▶ Cloudflare relay (Worker + Durable Object per room) ◀──wss── Parley app (Mac/Windows)
```

## Stages

1. **Relay + pairing + session overview** (this change). The phone shows the same overview as
   `/parley` (rings, states, timers, today's totals) and can press *Fortsetzen*.
2. **Call Parley** — a CallKit call from the phone to Parley; audio both ways over the relay.
   "Hey Siri, Parley" (App Intent, works in CarPlay) starts it. **Wake word during a call:**
   while nothing is being spoken (all sessions working), "Hey Parley" → Parley answers
   ("Ja, Sir, wie kann ich helfen?"), listens, and **routes** what you say: to a running
   session by its name, to Parley itself, to "new project", or to a general question.
3. **Zentrale** — a permanent Claude Code session (own folder, Parley voice on) that takes
   general requests: find projects, create projects (folder, `git init`, `.parley.json`),
   start new Claude Code sessions with Parley already active and a first task
   (as a terminal Claude Code CLI session; the desktop deep link only pre-fills the prompt).
4. **Incoming calls** — an update rings the phone: VoIP push (PushKit) → CallKit.
5. **Permission prompts aloud** — a session waiting for an approval is announced; "ja" answers it.

iOS limits: no always-on background wake word for third-party apps. Hands-free start is
"Hey Siri, Parley"; inside a call (or with the app open) the app listens for "Hey Parley".

## Pairing

The host (Parley app) creates, once, a room id (16 random bytes) and a secret (32 random
bytes), both base64url without padding, and keeps them with its settings. The pairing link is

```
parley://pair?u=<relay base URL, percent-encoded>&r=<room>&k=<secret>
```

"iPhone verbinden…" in the app's menu opens `https://<relay>/pair#<pairing link, percent-encoded>`
in the browser: the relay serves a static page that draws the link as a QR code **from the URL
fragment**, so the secret never reaches the relay in a request. The iPhone app scans it (or the
system camera opens it through the `parley://` URL scheme) and stores it in the Keychain.

## Relay protocol (v1)

One Durable Object per room. WebSocket endpoint:

```
GET wss://<relay>/v1/room/<room>?role=host|phone
Authorization: Bearer <secret>
```

- The first **host** connection to a room claims it: the relay stores `sha256(secret)` (hex).
  Every later connection (host or phone) must present a secret with the same hash, else `401`.
  A phone connecting to an unclaimed room gets `404`.
- One host per room (a new host connection replaces the old one); any number of phones.
- Frames are UTF-8 JSON text; every message has a type `t`. Binary frames are reserved for audio
  (stage 2). The text frame `ping` is answered `pong` by the relay itself (auto-response, no wake).

| `t`        | direction        | body |
|------------|------------------|------|
| `sessions` | host → phones    | the host's `GET /sessions` JSON (`sessions`, `today`, `reminders`) plus `at` (host clock, epoch ms). A row's `voice` means *holds the voice right now* (speaking/listening), not "voice mode on" — every listed session has voice mode. Sent on change, at least every 10 s. The relay keeps the latest one and sends it to a phone right after it connects. |
| `peer`     | relay → phones   | `{ "t": "peer", "host": true|false }` on connect and whenever the host comes or goes. |
| `resume`   | phone → host     | `{ "t": "resume", "id": "<session id>" }` — same as `POST /resume` on the host. |
| `hello`    | phone → host     | `{ "t": "hello", "device": "<name>" }` after connecting (informational). |

Unknown types are ignored by every side (forward compatible). The relay forwards host messages
to all phones and phone messages to the host; it inspects only `t` and keeps only the latest
`sessions` frame.

Trust: the relay runs in your own Cloudflare account and sees message contents (session names,
last spoken lines) over TLS. End-to-end encryption with a key derived from the secret is planned
together with audio (stage 2).

## Protocol v2 — calls, wake word, routing, push, permissions (stages 2–5)

Everything in v1 stays. Additions (unknown types are still ignored everywhere):

### Audio (binary frames)
- Raw **PCM 16-bit little-endian, mono, 16 kHz**, one frame per **20 ms (640 bytes)**. No header.
- phone → host: the phone's microphone while a call is connected. host → phone: Parley's voice.
- The relay forwards binary frames like text (host → phones, phone → host), never stores them;
  frames over 64 KB are dropped.

### Call control (text)
| `t`         | direction      | body / meaning |
|-------------|----------------|----------------|
| `call`      | phone → host   | `{"state":"start"}` the phone's CallKit call is connected (outgoing "Parley anrufen" or an answered incoming call); `{"state":"end"}` it ended. While a call is connected the host routes **all** Parley audio through the phone (TTS out, listening in) instead of the Mac's speaker/mic. |
| `audio`     | host → phone   | `{"state":"speaking"|"listening"|"idle"}` what the host is doing with the call audio (UI + the phone only listens for the wake word while `idle`). |
| `wake`      | phone → host   | the phone heard the wake word ("Hey Parley") while the host was `idle`. |
| `ring`      | host → phone   | `{"label":"<spoken project name>"}` an update wants the phone (sent alongside the VoIP push; a phone that is connected in the foreground can show its own incoming call from it). |
| `push`      | phone → host   | `{"token":"<hex VoIP push token>","env":"production"|"development"}` (TestFlight/App Store builds use `production`). |
| `away`      | phone → host   | `{"on":true|false}` **Unterwegs-Modus**: while on, updates ring the phone. |

### Host behaviour
- **Wake → greeting → listen → route.** On `wake` (host idle, call connected) the host plays a
  pre-recorded greeting ("Ja, Sir, wie kann ich helfen?", 3 variants, cached like the resume lines),
  listens on the phone audio, transcribes, and **routes** the utterance:
  1. a running Parley session whose label the utterance names (or clearly means) → that session;
  2. otherwise → the **Zentrale**.
  Routing uses the existing Groq LLM (labels + utterance → target), with a label substring match as
  fallback. Delivery reuses the resume paths: parked → `/wake` instruction; idle/working with the
  mod → pending instruction on its next `/presence` (the mod submits it as a prompt). The host
  confirms briefly ("Verstanden, ich gebe das an Tippfrei weiter.").
- **Zentrale.** A Claude Code session in `zentraleDir` (default `~/workspace/privat/parley-zentrale`,
  created from `zentrale/` in this repo: `CLAUDE.md` + `.parley.json` `{"name":"Zentrale"}`). If it
  is not alive, the host starts it as a visible interactive Claude Code CLI session in a terminal
  (macOS: Terminal.app via `osascript`, `cd <dir> && claude '/parley:voice'`; Windows: Windows
  Terminal `wt -d <dir> cmd /k claude /parley:voice`, `cmd` fallback) and keeps the routed instruction
  **pending by cwd** until a presence from that folder arrives. (The desktop deep link
  `claude://code/new?folder=…&q=…` was tested: it only pre-fills the prompt, so it can't start a
  session unattended.) The instruction text never goes on a command line.
  The Zentrale finds projects, creates projects under `projectsDir` (default `~/workspace/privat`:
  folder, `git init`, `.parley.json`), and starts new sessions the same way (terminal + first prompt
  `/parley:voice` + the task delivered as pending-by-cwd via `POST /dispatch`).
- **`POST /dispatch`** (local, for the Zentrale): `{"cwd":"<abs path>","instruction":"<task>","start":true}`
  → starts a session there if none is alive (terminal) and delivers the instruction to it.
- **Ringing (Unterwegs-Modus).** While `away` is on and no call is connected, a turn that is about to
  be voiced instead sends a **VoIP push** (APNs, topic `de.developaway.parley.mobile.voip`, push type
  `voip`, payload `{"label":…}`) plus a `ring` frame, and waits up to 45 s for `call start`; then it
  is voiced over the phone. Not reached (no answer, put off and missed, phone unreachable) →
  the line waits as a notification and the session parks: **in Unterwegs-Modus the Mac (PC)
  never speaks or listens itself** — not after a missed ring, nor when a call drops midway, and
  the resume dialog and permission questions ring the phone too (else: resume without dialog /
  the on-screen prompt). The phone stops an unanswered ring after 40 s (`call end`) and leaves
  the "later" notification; the host then keeps the ring open a minute for that choice.
  APNs credentials in credentials.json: `apnsKeyId`, `apnsTeamId` (`384887N3UL`), `apnsKeyP8`
  (the .p8 PEM text) — chosen once via the menu ("Push-Schlüssel wählen…", Key ID from the
  `AuthKey_<KEYID>.p8` file name). ES256 JWT, HTTP/2 to `api.push.apple.com`
  (`api.sandbox.push.apple.com` for `env: development`).
- **Permission prompts aloud.** The plugin's `PermissionRequest` hook long-polls
  `POST /permission` `{"session_id","cwd","tool_name","tool_input"}` (≤ 120 s). A session Parley
  does not know (voice mode off) gets `{"decision":"ask"}` at once (normal on-screen prompt).
  Otherwise it is queued like a turn: Parley says "<Projekt> möchte <kurze Beschreibung> — erlauben?",
  listens, and answers `{"decision":"allow"}` (ja / okay / mach / erlaub…), `{"decision":"deny"}`
  (nein / stopp…), or `{"decision":"ask"}` (unclear or no reply). The hook turns allow/deny into the
  `PermissionRequest` decision and prints nothing for `ask`.

### Phone behaviour
- **"Parley anrufen"** (button, App Intent "Hey Siri, Parley" — works in CarPlay) starts an outgoing
  CallKit call; on connect it sends `call start` and streams the mic (voice-processing I/O for echo
  cancellation), plays received audio, and sends `call end` when it ends.
- **Wake word**: during a connected call while the host reports `audio idle`, on-device speech
  recognition listens for "Hey Parley" and sends `wake`.
- **Incoming**: PushKit VoIP push → CallKit incoming call "Parley · <label>" → answering connects
  the relay (if needed) and sends `call start`. The phone registers its VoIP token with `push`.
- **Unterwegs-Modus** toggle in the app → `away`.

## Protocol v3 — session view, typing, Unterwegs + Stumm

Tapping a tile opens that session: its recent history (read by the host from Claude Code's own
transcript, `~/.claude/projects/<folder>/<session id>.jsonl`, last 3 MB), screenshots included, and
a text field that sends a message into the session. **Stumm** (only with Unterwegs on) replaces
the call with a notification; the session then waits for a typed reply.

| `t`       | direction      | body |
|-----------|----------------|------|
| `history` | phone → host   | `{"id":"<session>"}` send that session's newest history (the phone polls ~3 s while the view is open); with `"before":"<item id>"` the page right before that item (scrolled to the top). |
| `history` | host → phone   | `{"id":…,"before"?:…,"more":bool,"items":[{"id":"<uuid>#<n>","k":"user|voice|assistant|speak|tool|image","text":…,"who":"user|assistant","at":<ms>}]}` — ≤ 60 items, oldest dropped until the frame is ≤ 200 KB; `more` = older history exists. The newest page reads the transcript's last 3 MB, an older page the whole file. `voice` = a spoken reply, `speak` = the line Parley spoke, `tool` = "Bash · what for", `image` = a screenshot / pasted image (pixels via `image`). Empty `items` for a session without a transcript (Codex). |
| `image`   | phone → host   | `{"id":"<session>","key":"<item id>"}` |
| `image`   | host → phone   | `{"key":…,"mime":"image/jpeg","data":"<base64>"}` downscaled to fit one frame; `data` missing = not found. |
| `say`     | phone → host   | `{"id":"<session>","text":"…"}` delivered like a routed instruction: at once to a session that waits (parked / mod), else at its next turn. |
| `later`   | phone → host   | `{"after":60}` or `{}` — "not now" on the ringing screen (then `call end`). The host holds the line: rings again after `after` s (10–3600), or with no `after` waits up to 30 min for Sir's own call and thanks him first ("Danke für Ihren Rückruf, Sir."). Meanwhile the session's row in `sessions` carries `callback`: the ring time (ms), or `0` = waiting for the call back; the phone's tile shows "Rückrufen". Not reached in the end → a notification, the session parks. A ring declined on the lock screen (CallKit has no room for these buttons) leaves a notification with the same three actions; after such a decline (`call end` with no call) the host keeps the ring open one more minute for that `later`. |
| `silent`  | phone → host   | `{"on":true|false}` **Stumm**. With `away` on, a turn sends a notification push instead of ringing and parks the session (listen turns) until a `say` arrives. |
| `call`    | phone → host   | `{"state":"start","down":24000}` asks for Parley's voice at 24 kHz (the TTS's own rate): the host then sends 960-byte frames (20 ms) instead of 640-byte 16 kHz ones. Without `down`, 16 kHz as before; the phone plays either (by frame size). The mic stays 16 kHz. Host lead ~0.25 s, phone prebuffer 100 ms. |
| `caption` | host → phone   | `{"words":[…],"at":[<s>…],"end":<s>}` live captions for the line whose audio follows: word start times read off the synthesized audio (pauses ≥ 120 ms matched to the punctuation, words between by length; speaking rate applied). Sent just before the line's first frame; the phone times the words against the frames it actually played. |
| `slides`  | host → phone   | `{"items":[{"id","at","kind":"image|chart|metric|text","title","text","chart":"bar|line|pie","labels","values","unit","metric","note"}]}` the line's slides (docs/CALL-SLIDES.md), `at` on the caption clock; image pixels follow as `image` frames keyed by the slide id. |
| `push`    | phone → host   | `{"token","env","kind":"alert"}` the notification push token (topic `de.developaway.parley.mobile`); without `kind` it is the VoIP token as before. |

Notification push payload: `{"aps":{"alert":{"title":"Parley · <label>","body":"<spoken line>"},"sound":"default","thread-id":"<session>"},"session":"<session>"}` — tapping it opens that session.

### Resuming a past session (Zentrale)

`POST /past {"q":"<term>","limit":10}` → `{"sessions":[{"id","title","cwd","lastPrompt","lastAt"}]}`:
the newest of the 400 most recently written transcripts whose title (`custom-title` /
`summary`), folder or last prompt contains the term. `POST /dispatch {"resume":"<id>",
"instruction":…}` starts that session in its own folder as `claude --resume <id> '/parley:voice'`
(Terminal on macOS, Windows Terminal / cmd on Windows) — its whole history, voice mode on — and
the instruction waits for it like any dispatch; a session that still runs gets it directly.
Unknown or unsafe ids → 404.

### Closing a running session (Zentrale)

`POST /close {"id":"<id>"}` (or `{"ids":[…]}`, or `{"project":"<label or folder name>"}` = every
running session of it) → `{"ok","closed":[{"id","label"}],"failed":[{"id","error"}]}`; 200 when
any closed, else the first failure's code: 404 unknown, 403 the Zentrale (by label or folder — it
never closes itself), 409 already stopped / no closable process. The host finds the session's
`claude` process (`~/.claude/sessions/<pid>.json`, else `--resume <id>` in its command line;
macOS also: the only unclaimed terminal one in its folder), ends it (macOS: SIGTERM to its
process group, then closes its Terminal window if it was the only tab; a Claude desktop session:
SIGTERM to its own group under the app's `disclaimer --pgroup` helper — claude and its MCP
servers, not the app or its other sessions; Windows: kills the `cmd /k` console tree, or just the
claude tree of a desktop session) and marks it `stopped` at once — a dying mod's last presence
within 20 s is ignored. The transcript stays, so `/past` + `/dispatch` resume continue it; the
desktop app resumes its session itself on the next message there.

## Protocol v4 — the Live Activity (Dynamic Island, Lock Screen, Watch, CarPlay)

Phone → host: `{"t":"activity","start":"<hex>","env":…}` (its push-to-start token) and
`{"t":"activity","token":"<hex>"|"","env":…}` (the running activity's update token; `""` = none
runs any more). Both are kept in the host's credentials, like the push tokens.

The host owns the activity (macOS `LiveActivity.swift`, Windows `LiveActivity.cs`): every 2 s it
turns `GET /sessions` into the `content-state` — `sessions` (at most 4, most urgent first: owed
call back, ring to come, talking, wanting to talk, paused, working, background, parked, ready;
`id`, `label`, `state`, `since`, `until`, `callback` in epoch **seconds**), `alive`, `line` / `from`
(the most urgent session's last spoken line), `ask` (Stumm, or a ring not answered: the
latest question — `id`, `label`, `text`, up to 3 `options` from its `<reply on>` predictions —
until it is answered or its session works again) — and pushes `apns-push-type: liveactivity` to
`de.developaway.parley.mobile.push-type.liveactivity`:

- **start** (push-to-start, priority 10, with an alert "Parley unterwegs"): Unterwegs on and a
  session runs, no activity yet; retried at most once a minute.
- **update** on every change, at least 1 s apart and every 10 min as a heartbeat (`stale-date` =
  now + 15 min, so a silent Mac shows as stale); priority 5 (not budgeted), 10 when a session
  newly wants Sir.
- **end** when Unterwegs goes off or nothing has run for 2 min; before 8 h it ends and starts a
  new one (iOS's limit). An end the host did not push is Sir's swipe: no new start until
  Unterwegs goes off and on again. 410 / BadDeviceToken drops that token.

A tapped option goes to the session as a `say` (typed text); the activity shows it as sent at
once. The phone (`ActivityLink`) otherwise only hands over tokens, keeps one activity (a newer one ends the
older) and ends it at once when Unterwegs goes off. Its controls (Control Center, Lock Screen,
Action Button: "Parley anrufen", "Unterwegs", "Stumm") and the activity's call button are
`LiveActivityIntent`s — they run in the app's process, which dials the relay in the background
to tell the host. The switches live in the App Group `group.de.developaway.parley`.

**Widgets.** The phone's widgets show what the app last stored in the App Group — from each
`sessions` frame while it runs, and from the host's **silent push** while it doesn't: `apns-push-
type: background`, priority 5, topic `de.developaway.parley.mobile`, to the notification token,
`{"aps":{"content-available":1},"widget":{sessions (up to 8, as above), line, from, cost, updates,
limit, week}}`. iOS throttles these, so the host sends one at most every 20 min and only when the
sessions, the line or the limit (whole %) changed. An old picture shows "Stand hh:mm".

**Subtitles in a call.** While a call runs the app sets `caption` / `speaker` on the running
activity itself (local updates, no push): the line spoken now, so the Lock Screen and the expanded
Island follow the talk. A host push in between clears them; the next line brings them back.

### A colour palette made by voice (Zentrale)

`POST /palette {"name","note"?,"alwaysDark"?,"colors":{role: "#RRGGBB" | ["#light","#dark"]}}` with
all ten roles (background, card, raised, accent, waiting, working, purple, idle, stopped, red) →
`{"ok":true,"name"}`, or 400 naming missing / invalid roles. The host sends the phone
`{"t":"palette","name","note","alwaysDark","colors":{role:["#L","#D"]}}` at once and again on every
`hello` (the phone's (re)connect) until the phone answers `{"t":"palette","saved":"<name>"}`. The
phone saves it under "Eigene" (same name = replaced) and switches to it. The Zentrale researches
the palette (Playwright) — see zentrale/CLAUDE.md, "Farbpalette erstellen".

### Barge-in — Sir talks over Parley

The call's mic is echo-cancelled (`.voiceChat` voice processing). While the host speaks, the
phone runs its on-device recognizer on it and counts as an interruption only what can't be
Parley's own echo: a stop word ("Stopp", "Moment", "Warte" …) Parley didn't just say, or two
words not in its current / previous line (no captions → stop words only); the first 0.6 s are
ignored while the echo canceller settles. Then the phone silences its playback at once (queued
frames dropped until the host stops speaking) and sends `{"t":"barge"}`. The host stops the line
(nothing of it moves to the Mac's speaker), skips the beep and listens — starting with the phone's
last 2 s of mic, so the first words count; after a speak-only line too (the hook injects any
transcript). Einstellungen → "Parley unterbrechen" (on by default).

Without a call the host does the same on its own speaker (menu / tray "Parley unterbrechen",
on by default):

- **Mac** (`Barge.swift`): an on-device `SFSpeechRecognizer` (de-DE) on the playback engine's
  echo-cancelled mic (AVAudioEngine voice processing) — or, when the voice goes to Bluetooth
  headphones, on the built-in mic (no echo there; the headphones' own mic would drop them to call
  quality). A barge cuts the voice, skips the beep and records with the last 2 s of that mic.
  Asks once for speech recognition.
- **Windows** (`Barge.cs`): Windows speech recognition (German dictation; needs
  "Online-Spracherkennung" on) while the line plays; a WASAPI capture keeps the last 2 s. No echo
  cancellation — the word rule is the guard.

### Fragerunde, Wachhund, Unterwegs by itself

- **Fragerunde:** for 4 min after a call ends, a new update doesn't ring: it waits (`queued`, the
  Island shows it), others line up, then one ring for all — "Ich habe drei Updates für Sie, Sir."
  Calling in starts the round at once; permission prompts never wait.
- **Wachhund:** every 30 s, each working session's transcript tail (same tool call 4× in the last
  8, the last 6 failed, or 10 min silent after 15 min of work) → Sir is asked "Soll ich
  eingreifen?" (a `watchdog` dialog like a permission prompt) or notified when Unterwegs; a yes
  sends the session a hint (pending instruction — read at its next step). Once per kind per
  session per 30 min.
- **Unterwegs by itself:** the phone's Focus filter (on with a Focus, off when it ends), the
  Shortcuts actions (CarPlay, leaving home), and on the host "Unterwegs, wenn der Mac / PC
  gesperrt ist" (locked ≥ 1 min; off by default) — the phone's own choice stays its own.
- **Fortsetzen** also for sessions with work in the background (Claude Code takes a prompt then).
- **Wiedervorlage:** the Zentrale turns "erinnere Shirts morgen um neun …" into `POST /remind`
  (`to`, `text`, one of `at` / `in` / `after`; no `to` = for Sir); `GET /remind` lists,
  `POST /remind/cancel {id}` removes. The host keeps them in `reminders.json` and checks every
  30 s and at each session's turn end ("after"). Due for a session: its instruction ("Wiedervorlage
  von Sir …"), resumed or started in its folder if it doesn't run. Due for Sir: a `reminder`
  dialog, spoken like an update (the phone rings when Unterwegs). `/sessions` carries
  `reminders: [{id, text, to, at (ms) | null, after | null}]`; the phone lists them under the
  sessions.

