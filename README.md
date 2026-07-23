# Parley

**A voice layer for Claude Code.** When a Claude Code turn ends, Parley speaks the
summary aloud, listens to your spoken reply, and feeds it straight back into the same
session — a fluid, hands-free conversation with your coding agent, in the character of a
calm, dry-witted butler.

Works in **any terminal** (Warp, iTerm, tmux, …) — no keystroke injection, no setup of
your shell.

## Install

**Recommended — let Claude Code install it for you.** Paste this prompt into any Claude Code session; it guides you to the two API keys (both effectively **free**) and sets everything up:

> Install Parley (github.com/Lidyrius/parley), a voice layer for Claude Code, on this Mac:
> 1. First walk me through getting the two API keys — both are basically free:
>    - **Groq** (speech-to-text, free developer tier — no payment needed): guide me step by step: console.groq.com → sign in → API Keys → Create API Key.
>    - **Google Cloud Text-to-Speech** (the voice, first **1 million characters/month free**): guide me step by step: console.cloud.google.com → create or select a project → search "Cloud Text-to-Speech API" → Enable → APIs & Services → Credentials → Create credentials → API key.
> 2. Ask me for both keys, my spoken language, and my preferred Chirp3-HD voice (default: Alnilam).
> 3. Write them to `~/Library/Application Support/Parley/credentials.json` (chmod 600) as JSON with keys `googleAPIKey`, `groqAPIKey`, `language` (e.g. "Deutsch"), `googleVoice` (e.g. "de-DE-Chirp3-HD-Alnilam").
> 4. Then run `curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash` — it detects the credentials, skips the interactive onboarding, downloads the prebuilt app and renders my voice clips.
> 5. Finally tell me to start a **new** Claude Code session and type `/parley:voice`.

**Or by hand — one command** (a short terminal onboarding asks for the keys):

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

Re-running the same command later **updates** Parley in place — keys, settings and statistics are kept.

---

## How it works

```
Claude Code turn ends
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
- 🎚️ **Your voice** — pick any Google Chirp3-HD voice during onboarding.
- 🖥️ **Terminal-agnostic** — Warp, iTerm, tmux, plain Terminal.

## Requirements

- **macOS 14+** (Sonoma or newer) — Liquid Glass UI on macOS 26, plain material below
- `jq`, `git`, `curl` — **no Xcode**: the installer downloads a prebuilt app
- A **Google Cloud TTS** API key (speech, 1M chars/month free) and a **Groq** API key (transcription)

On the first real turn, grant **Microphone**. No Accessibility needed (media pause uses MediaRemote).

## Usage

1. Start (or restart) a Claude Code session.
2. Type `/parley:voice` — you'll hear a greeting.
3. Work as usual. When a turn finishes, Parley speaks the summary and listens.
4. Reply by voice; stop talking and it's injected back automatically.

Re-run onboarding anytime with `bash scripts/onboard-tui.sh`.

## Configuration

Settings live in the menu-bar app (**Settings…**) and in onboarding:

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
