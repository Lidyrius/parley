# Parley

**A voice layer for Claude Code.** When a Claude Code turn ends, Parley speaks the
summary aloud, listens to your spoken reply, and feeds it straight back into the same
session — a fluid, hands-free conversation with your coding agent, in the character of a
calm, dry-witted butler.

Works in **any terminal** (Warp, iTerm, tmux, …) — no keystroke injection, no setup of
your shell.

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

Then start a new Claude Code session and type `/parley:voice`.

---

## How it works

```
Claude Code turn ends
        │  Stop hook (blocks) — extracts the spoken <speak> line
        ▼
   Parley.app  (menu-bar, 127.0.0.1:8787)
     1. pause any playing media
     2. speak the summary        ── ElevenLabs TTS (your voice, e.g. "Jarvis")
     3. 🎤 record your reply      ── live waveform pill, silence-detected end
     4. transcribe               ── Groq Whisper
     5. resume media
        │  returns the transcript
        ▼
   Stop hook emits {"decision":"block", reason: <transcript>}
        │
        ▼  Claude continues with your spoken reply as the next turn
```

The hook long-polls the app and injects the reply via Claude Code's stop decision — so
it's completely terminal-agnostic.

## Features

- 🗣️ **Spoken summaries** — Claude ends each turn with a short spoken line, in your
  language and in the Jarvis character.
- 🎤 **Voice replies** — talk back; silence ends the recording automatically.
- 🌊 **Live waveform pill** — a floating, always-on-top capsule shows it's listening and
  a volume-pulsing orb, so you know you're heard.
- ⏯️ **Smart media pause** — pauses YouTube/Spotify while speaking, resumes after —
  and leaves already-paused media alone.
- 🌍 **Any language** — pick the spoken language in onboarding.
- 🎚️ **Your voice** — choose any ElevenLabs voice (clone or premade).
- 🖥️ **Terminal-agnostic** — Warp, iTerm, tmux, plain Terminal.

## Requirements

- **macOS 14+** (Sonoma or newer) — Liquid Glass UI on macOS 26, plain material below
- `jq`, `git`, `curl` — **no Xcode**: the installer downloads a prebuilt app
- A **Google Cloud TTS** API key (speech, 1M chars/month free) and a **Groq** API key (transcription)

On the first real turn, grant **Microphone**. No Accessibility needed (media pause uses MediaRemote).

## Install

**One command:**

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

**Or one prompt** — paste into Claude Code:

> Install Parley for me: run
> `curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash`
> in the terminal, then tell me to start a new session and run `/parley:voice`.

The installer builds `Parley.app` into `~/Applications`, installs the plugin into
`~/.claude/skills/parley` (auto-loads every session), and runs a short terminal
onboarding (API keys, language, voice, microphone).

## Usage

1. Start (or restart) a Claude Code session.
2. Type `/parley:voice` — you'll hear a greeting.
3. Work as usual. When a turn finishes, Parley speaks the summary and listens.
4. Reply by voice; stop talking and it's injected back automatically.

Re-run onboarding anytime with **Setup…** in the menu-bar app, or
`bash scripts/onboard-tui.sh`.

## Configuration

Settings live in the menu-bar app (**Settings…**) and in onboarding:

- **Language** of the spoken summaries
- **Voice** (ElevenLabs)
- **Microphone** input device
- **API keys** — stored locally in `~/Library/Application Support/Parley/credentials.json`
  (`0600`), never transmitted anywhere but ElevenLabs/Groq.

## Uninstall

```bash
rm -rf ~/Applications/Parley.app \
       ~/.claude/skills/parley \
       "~/Library/Application Support/Parley"
defaults delete de.developaway.parley 2>/dev/null || true
```

## Built with

Swift 6 / SwiftUI (menu-bar, Liquid Glass) · ElevenLabs (TTS) · Groq Whisper (STT) ·
a Claude Code plugin (Stop-hook long-poll).

## License

MIT
