# Install Parley

Voice layer for Claude Code — Claude speaks each turn's summary, you reply by voice,
it's injected back into the session. Works in any terminal.

## One command (human)

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

Builds the macOS app, installs the Claude Code plugin, and runs a terminal onboarding
(API keys, language, voice, microphone). Then start a **new** Claude Code session and
type `/parley:voice`.

## One prompt (paste into Claude Code)

> Install Parley for me: run
> `curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash`
> in the terminal. It builds the app, installs the plugin, and walks me through
> onboarding. When it finishes, tell me to start a new session and run `/parley:voice`.

Claude runs the installer, the terminal onboarding collects your settings, and the
plugin auto-loads (`parley@skills-dir`) — so `/parley:voice` is available in your next
session with no further setup.

## Requirements

- macOS 26 (Tahoe) · Xcode 26 toolchain (`swift`) · `jq` · `git` · `curl`
- ElevenLabs API key (speech) · Groq API key (transcription)
- On the first real turn, grant **Microphone** and (for media pause) **Accessibility**.

## What it does

1. `scripts/make-app.sh` — builds `Parley.app` (stable-signed) into `~/Applications`.
2. Symlinks `plugin/` into `~/.claude/skills/parley` (auto-loads every session).
3. `scripts/onboard-tui.sh` — terminal onboarding → writes the local credential store
   and marks onboarding complete.

Re-run onboarding anytime: `bash scripts/onboard-tui.sh` (or **Setup…** in the menu-bar app).
