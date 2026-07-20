# Vloude — Build Briefing (for the Ralph loop)

You are building **Vloude**: a voice-conversation layer over Claude Code. When a Claude Code
turn ends, a macOS app speaks a short spoken summary (ElevenLabs TTS), records the user's spoken
reply (mic + VAD → Groq transcription), and types that reply back into the *same* Claude Code
session via `tmux send-keys`. It feels like a fluid back-and-forth conversation across many
open Claude Code sessions.

This file is the immutable spec. Your live checklist is `PROGRESS.md`. The wire format is
`CONTRACT.md`. **Read all three every iteration.**

---

## Fixed product decisions (do NOT re-litigate)

- **No Claude Agent SDK.** The user keeps their normal interactive Claude Code TUI sessions.
  Integration is a **plugin (skill + Stop hook)** + the desktop app. Replies go back via
  `tmux send-keys`, never by owning headless sessions.
- **The skill is the toggle.** The Stop hook fires every turn once the plugin is enabled, but only
  POSTs when the assistant message contains a `<speak>…</speak>` line. Claude only emits `<speak>`
  after the `/vloude:voice` skill is invoked. So skill-invoked = voice mode on. (Already built.)
- **Multi-instance from day one.** Routing is a **queue**: the app speaks finished sessions one at
  a time. Which session a reply goes to is identified by `tmux_pane` (`$TMUX_PANE`), carried in the
  hook POST. No project-name matching needed.
- **Mic trigger:** after speaking, play a short beep, then auto-listen with **RMS silence-based VAD**
  (~1.2 s trailing silence ends the recording).
- **Media pause in MVP:** before speaking, send the system Play/Pause media key so YouTube/Spotify
  pauses; send it again after. Requires Accessibility (user grants manually).
- **Summary source:** Claude writes its own spoken line inside `<speak>…</speak>`. No extra LLM call.

## Stack

- **App:** Swift 6 / SwiftUI, macOS 26 (Tahoe) SDK, menu-bar agent (`LSUIElement`, `MenuBarExtra`).
  Liquid Glass via `.glassEffect()` / `GlassEffectContainer`. **Non-sandboxed**, Developer-ID
  signable (Accessibility + media keys + loopback server need no sandbox fights).
- **Build system:** **Swift Package Manager executable target** (a `Package.swift`), so the whole
  app builds and verifies with `swift build -c release` — no hand-authored `.xcodeproj`. Declare
  `.macOS(.v26)`. The executable is a SwiftUI `@main App` with `MenuBarExtra`.
- **TTS:** ElevenLabs `eleven_flash_v2_5`, HTTP `/stream` endpoint, request **PCM**
  (`pcm_24000`), play via `AVAudioEngine` + `AVAudioPlayerNode` scheduling PCM buffers. Auth header
  `xi-api-key`.
- **STT:** Groq `whisper-large-v3-turbo`, `POST /openai/v1/audio/transcriptions`, multipart,
  16 kHz mono WAV, `Authorization: Bearer`.
- **HTTP server:** loopback `127.0.0.1:8787` (`Network.framework` `NWListener`, or a minimal
  hand-rolled socket server). Routes: `GET /health`, `POST /turn`, `POST /ready` (see CONTRACT.md).
- **Media keys:** `NSEvent` `systemDefined` subtype 8, `NX_KEYTYPE_PLAY = 16`, down+up, post to
  `.cghidEventTap`. Gate on `AXIsProcessTrustedWithOptions`.
- **Secrets:** ElevenLabs + Groq API keys stored in the macOS **Keychain**; a Settings window to
  enter them + pick a voice id. Never hard-code keys.

## Repository layout (target)

```
vloude/
├── plugin/                     # Claude Code plugin — ALREADY SCAFFOLDED, keep working
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json         # Stop hook → scripts/stop-hook.sh
│   ├── scripts/stop-hook.sh     # extracts <speak>, POSTs /turn with $TMUX_PANE
│   └── skills/voice/SKILL.md    # the toggle: greet + emit <speak> each turn
├── app/                        # the SwiftUI menu-bar app (SPM package) — BUILD THIS
│   ├── Package.swift
│   ├── Sources/Vloude/...       # App, Server, TTS, STT, Audio, VAD, Tmux, MediaKeys, UI, Keychain
│   └── Tests/VloudeTests/...    # unit tests for the pure logic
├── scripts/generate-ready-clips.sh   # pre-render 10 "ich bin bereit" ElevenLabs clips
├── CONTRACT.md   BRIEFING.md   PROGRESS.md
└── tests/hook_test.sh          # shell test for stop-hook.sh speak-extraction + no-tag skip
```

## What is ALREADY DONE (verify, don't rebuild)

- `plugin/` scaffolded: `plugin.json`, `hooks/hooks.json`, `scripts/stop-hook.sh` (chmod +x),
  `skills/voice/SKILL.md`. The stop-hook was manually tested: with a `<speak>` tag it POSTs a clean
  JSON `/turn` (speak text extracted, `$TMUX_PANE` included); with no tag it exits 0 and POSTs
  nothing. `CONTRACT.md` written. If you improve these, keep the contract stable.

---

## Verification is the loop's fuel — only claim done what a command proves

Every iteration: build and test, read the output, fix what failed. Completion criteria are things
this autonomous loop can actually check. **Audio, microphone, Accessibility, and GUI runtime
behaviour CANNOT be verified in the loop** (no devices/permissions/display) — those go into a
**manual smoke-test checklist** (`SMOKE_TEST.md`) for the human, and are NOT part of the promise.

Make the pure logic unit-testable and test it:
- `<speak>` extraction + no-tag skip (shell test `tests/hook_test.sh`, run it).
- RMS / dB computation and the silence-timer state machine (given fake sample buffers).
- VAD end-of-speech decision (thresholds, trailing-silence window).
- tmux command construction (correct `send-keys -t <pane> -l` + separate Enter; shell-safe).
- Turn queue (FIFO, one active at a time, pane routing).
- HTTP request parsing/response for `/turn`, `/ready`, `/health`.
- ElevenLabs + Groq request builders (URL, headers, multipart shape) — test construction, not live
  calls. If `ELEVENLABS_API_KEY` / `GROQ_API_KEY` are present in env, one optional live smoke call is
  fine; otherwise skip gracefully.

## Guardrails

- Local git commits per iteration are expected (init the repo if absent). **Do not push.** Do not
  touch anything outside this repo.
- Keep the shortest diff that works; no speculative abstractions. Match existing style.
- Don't fabricate green: if `swift build` or a test fails, the item stays unchecked.
- You cannot grant Accessibility/mic permission or run a GUI — never block on that. Put it in
  `SMOKE_TEST.md` and move on.
- If genuinely stuck on an item for several iterations, write the blocker into `PROGRESS.md` under
  that item, skip it, and keep going on the rest.

## Definition of done (output the promise ONLY when ALL are true)

1. Every box in `PROGRESS.md` is checked (or explicitly marked blocked with a written reason).
2. `cd app && swift build -c release` succeeds with no errors.
3. `cd app && swift test` passes.
4. `bash tests/hook_test.sh` passes.
5. `SMOKE_TEST.md` exists listing the manual runtime checks (audio, mic, Accessibility, tmux inject,
   end-to-end) the human must do.

When and only when 1–5 hold, output exactly: `<promise>VLOUDE_DONE</promise>`
