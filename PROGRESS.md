# Vloude — Progress (Ralph updates this every iteration)

Check a box `[x]` ONLY when its verify command passes. Add a short note per item if useful.
Blocked? Leave `[ ]` and write `BLOCKED: <reason>` under it.

## Phase 0 — Repo & scaffolding
- [x] `git init` done, `.gitignore` for Swift/`.build/`/`.DS_Store`/secrets, initial commit
- [x] `plugin/` scaffolded (plugin.json, hooks.json, stop-hook.sh, skills/voice/SKILL.md) — pre-built
- [x] `CONTRACT.md`, `BRIEFING.md` present — pre-built

## Phase 1 — Plugin hardening + hook tests
- [x] `tests/hook_test.sh`: asserts `<speak>` extraction → correct `/turn` JSON, and no-tag → no POST
      (spin a throwaway local listener, capture the body). Verify: `bash tests/hook_test.sh`
- [x] stop-hook handles multiline / quotes / unicode in speak text without breaking JSON
      (hook uses jq for JSON assembly; test 2 asserts unicode/quotes/newlines round-trip)

## Phase 2 — App skeleton builds
- [x] `app/Package.swift`: executable target `Vloude`, platform `.macOS(.v26)`, SwiftUI
- [x] `@main` SwiftUI App with `MenuBarExtra`, `LSUIElement` behaviour (menu-bar only, no dock)
- [x] Verify: `cd app && swift build -c release` succeeds
- [x] Verify: `cd app && swift test` runs (even if only a trivial test at first)

## Phase 3 — Loopback HTTP server + turn queue
- [x] `NWListener` (or minimal socket) on `127.0.0.1:8787`, routes `/health` `/turn` `/ready`
- [x] Decode `/turn` + `/ready` payloads (CONTRACT.md) into typed structs
- [x] FIFO turn queue: one active turn at a time, keyed/routed by `tmux_pane`
- [x] Tests: request parsing, `/health` 200, queue FIFO + single-active

## Phase 4 — TTS playback
- [x] ElevenLabs client: `flash_v2_5`, `/stream`, `pcm_24000`, `xi-api-key` header (request builder tested)
- [x] `AVAudioEngine` + `AVAudioPlayerNode` streams PCM buffers as chunks arrive
- [x] Beep after speech finishes

## Phase 5 — Mic capture + VAD + STT
- [x] `AVAudioEngine` input tap; RMS→dB per buffer (unit tested)
- [x] Silence-timer VAD state machine: reset on speech, stop after ~1.2 s silence (unit tested)
- [x] Encode captured audio to 16 kHz mono WAV
- [x] Groq client: `whisper-large-v3-turbo`, multipart transcription (request builder tested)

## Phase 6 — Inject reply + media control
- [x] tmux inject: `send-keys -t <pane> -l <text>` then `send-keys -t <pane> Enter`, shell-safe
      for quotes/newlines (command construction unit tested)
- [x] Empty `tmux_pane` → speak only, log that inject was skipped (don't crash)
- [x] Media key Play/Pause via `NSEvent` systemDefined subtype 8, `NX_KEYTYPE_PLAY`; gate on
      `AXIsProcessTrusted`; pause before speaking, resume after

## Phase 7 — Ready clips
- [x] `scripts/generate-ready-clips.sh`: render 10 varied "ich bin bereit" clips via ElevenLabs into
      `app/Sources/Vloude/Resources/ready/` (skips gracefully w/o API key), bundled as SPM resources
- [x] `/ready` handler plays a random bundled clip

## Phase 8 — Menu-bar UI (Liquid Glass)
- [x] `MenuBarExtra` panel: list active/finished sessions (project label + status + pane), Liquid
      Glass styling (`.glassEffect`, `GlassEffectContainer`)
- [x] Settings window: API keys → Keychain, voice-id picker
- [x] Info.plist keys via SPM: `NSMicrophoneUsageDescription`, `LSUIElement`

## Phase 9 — Wire the full loop
- [x] `/turn` → pause media → speak → beep → record → VAD stop → transcribe → tmux inject → resume
- [x] Queue drains finished sessions one at a time end-to-end (logic path, no devices)
- [x] Final `swift build -c release` + `swift test` green

## Phase 10 — Manual smoke test doc
- [x] `SMOKE_TEST.md`: step-by-step human checks — grant Accessibility+mic, enable plugin
      (`claude --plugin-dir …/plugin`), run `/vloude:voice`, confirm greeting, finish a turn, hear
      summary, reply by voice, see it typed back into the tmux pane; YouTube pause/resume
