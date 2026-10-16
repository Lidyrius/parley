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
   (`claude://code/new?folder=…&q=…`, to be verified; CLI fallback).
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
| `sessions` | host → phones    | the host's `GET /sessions` JSON (`sessions`, `today`) plus `at` (host clock, epoch ms). Sent on change, at least every 10 s. The relay keeps the latest one and sends it to a phone right after it connects. |
| `peer`     | relay → phones   | `{ "t": "peer", "host": true|false }` on connect and whenever the host comes or goes. |
| `resume`   | phone → host     | `{ "t": "resume", "id": "<session id>" }` — same as `POST /resume` on the host. |
| `hello`    | phone → host     | `{ "t": "hello", "device": "<name>" }` after connecting (informational). |

Unknown types are ignored by every side (forward compatible). The relay forwards host messages
to all phones and phone messages to the host; it inspects only `t` and keeps only the latest
`sessions` frame.

Trust: the relay runs in your own Cloudflare account and sees message contents (session names,
last spoken lines) over TLS. End-to-end encryption with a key derived from the secret is planned
together with audio (stage 2).
