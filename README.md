# Parley

**A voice layer for Claude Code and Codex.** When an agent turn ends, Parley speaks the
summary aloud, listens to your spoken reply, and feeds it straight back into the same
session — a fluid, hands-free conversation with your coding agent, in the character of a
calm, dry-witted butler.

Works in **any terminal** (Warp, iTerm, tmux, …) — no keystroke injection, no setup of
your shell.

## Install

**macOS — one command:**

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

**Windows — one command** (PowerShell; tray app, works with Claude Code in Git Bash and WSL):

```powershell
irm https://raw.githubusercontent.com/Lidyrius/parley/main/windows/install.ps1 | iex
```

On first launch Parley opens a **setup window** that guides you through the two API keys
(both effectively **free** — Groq's dev tier and Google Cloud TTS's 1M chars/month), with
a button to open each console and a live key check, then language, voice, notification
style, and client integrations. If Claude Code or Codex is installed, it is detected and
preselected; both can be enabled together. Start a **new** session and activate
`/parley:voice` in Claude Code or `$parley-voice` in Codex.

Re-running the install command later **updates** Parley in place — keys, settings and
statistics are kept.

---

## How it works

```
Claude Code or Codex turn ends
        │  Stop hook (blocks) — extracts the spoken <speak> line
        ▼
   Parley.app  (menu-bar, 127.0.0.1:8787)
     1. pause any playing media
     2. speak the summary        ── Google TTS (Chirp3 HD)
     3. 🎤 record your reply      ── live waveform pill, silence-detected end
     4. transcribe               ── Groq Whisper
     5. resume media
        │  returns the transcript
        ▼
   Stop hook emits a client-compatible continuation decision
        │
        ▼  The agent continues with your spoken reply as the next turn
```

The hook long-polls the app and injects the reply through the host's stop decision — so
it's completely terminal-agnostic. In Codex, activate the skill explicitly with
`$parley-voice`; Claude Code keeps `/parley:voice`.

## Features

- 🗣️ **Spoken summaries** — the agent ends each turn with a short spoken line, in your
  language and in the Jarvis character.
- 🎤 **Voice replies** — talk back; silence ends the recording automatically.
- 🌊 **Live waveform pill** — a floating, always-on-top capsule shows it's listening and
  a volume-pulsing orb, so you know you're heard.
- ⏯️ **Smart media pause** — pauses YouTube/Spotify while speaking, resumes after —
  and leaves already-paused media alone.
- 🌍 **Any language** — pick the spoken language in onboarding.
- 🎚️ **Your voice** — pick any Google Chirp3-HD voice during onboarding.
- 🖥️ **Terminal-agnostic** — Warp, iTerm, tmux, plain Terminal.

## Requirements

- **macOS 14+** (Sonoma or newer) — Liquid Glass UI on macOS 26, plain material below
- `jq`, `git`, `curl` — **no Xcode**: the installer downloads a prebuilt app
- A **Google Cloud TTS** API key (speech, 1M chars/month free) and a **Groq** API key (transcription)

On the first real turn, grant **Microphone**. No Accessibility needed (media pause uses MediaRemote).

## Usage

1. Start (or restart) a Claude Code or Codex session.
2. Type `/parley:voice` in Claude Code or `$parley-voice` in Codex — you'll hear a greeting.
3. Work as usual. When a turn finishes, Parley speaks the summary and listens.
4. Reply by voice; stop talking and it's injected back automatically.

Codex may ask you to review the bundled Stop hook once; open `/hooks`, review and trust
Parley, then start a fresh thread and invoke `$parley-voice`.

Re-run setup anytime via **Setup…** in the menu-bar / tray app.

## Configuration

Settings live in the menu-bar / tray app (**Settings…**) and the first-run setup window:

- **Language** of the spoken summaries
- **Voice** (Google Chirp3 HD)
- **Microphone** input device
- **API keys** — stored locally in `~/Library/Application Support/Parley/credentials.json`
  (`0600`), never transmitted anywhere but Google/Groq.

### Per-project name

Drop a `.parley.json` in a project root to give it a spoken name:

```json
{ "name": "Parley" }
```

When **more than one project runs in parallel**, Parley prepends a short spoken
announcement — *"I have an update on the Parley project"* — before each summary, so you
always know which one is talking. These announcements are pre-rendered per project (10
phrasings, your voice + language) and cached; with a single project running, nothing is
prepended.

## Uninstall

```bash
rm -rf ~/Applications/Parley.app \
       ~/.claude/skills/parley \
       "~/Library/Application Support/Parley"
defaults delete de.developaway.parley 2>/dev/null || true
```

## Built with

Swift 6 / SwiftUI (menu-bar, Liquid Glass) · Google Cloud TTS Chirp3 HD · Groq Whisper (STT) ·
a Claude Code plugin (Stop-hook long-poll).

## License

MIT
