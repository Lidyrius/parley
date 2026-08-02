# Install Parley

Voice layer for Claude Code and Codex — the agent speaks each turn's summary, you reply by voice,
it's injected back into the session. Works in any terminal.

## One command (human)

```bash
curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
```

Builds the macOS app, installs the shared Claude Code/Codex plugin, and runs onboarding
(API keys, client selection, language, voice, microphone). Then start a **new** session
and type `/parley:voice` in Claude Code or `$parley-voice` in Codex.

## One prompt (paste into Claude Code)

> Install Parley for me: run
> `curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash`
> in the terminal. It builds the app, installs the shared plugin, detects Claude Code
> and Codex, and walks me through onboarding. When it finishes, tell me to start a new
> session and activate `/parley:voice` or `$parley-voice`.

The installer detects both clients and the setup window lets you enable either or both.
Claude Code loads `/parley:voice`; Codex loads the local plugin and exposes
`$parley-voice` for explicit activation. On first Codex use, review and trust the
bundled Stop hook with `/hooks`, then start a fresh thread.

## Requirements

- macOS 26 (Tahoe) · Xcode 26 toolchain (`swift`) · `jq` · `git` · `curl`
- ElevenLabs API key (speech) · Groq API key (transcription)
- On the first real turn, grant **Microphone** and (for media pause) **Accessibility**.

## What it does

1. `scripts/make-app.sh` — builds `Parley.app` (stable-signed) into `~/Applications`.
2. Detects installed clients and synchronizes Claude Code and/or the local Codex marketplace.
3. `scripts/onboard-tui.sh` — terminal onboarding → writes the local credential store
   and marks onboarding complete.

Re-run onboarding anytime: `bash scripts/onboard-tui.sh` (or **Setup…** in the menu-bar app).
