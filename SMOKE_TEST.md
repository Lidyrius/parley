# Vloude — Manual Smoke Test

These checks need real audio, a microphone, macOS Accessibility permission, a live
tmux session, and API keys — none of which the autonomous build loop can exercise.
Do them by hand once before relying on Vloude.

## Prerequisites

- [ ] Build the app: `cd app && swift build -c release`
- [ ] Set API keys (either in the Settings window, or export before launch):
      `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `GROQ_API_KEY`
- [ ] (Optional) Pre-render greeting clips: `bash scripts/generate-ready-clips.sh`
      (needs the ElevenLabs env vars; writes `app/Sources/Vloude/Resources/ready/*.pcm`)

## Permissions (granted manually — the loop cannot)

- [ ] Launch the app: `./app/.build/release/Vloude` (menu-bar icon appears, no dock icon)
- [ ] System Settings → Privacy & Security → **Microphone**: enable Vloude
- [ ] System Settings → Privacy & Security → **Accessibility**: enable Vloude
      (required for the media Play/Pause key)

## Settings

- [ ] Open the menu-bar panel → Settings… → enter both API keys + a voice id → Save to Keychain
- [ ] Reopen Settings: values reload from Keychain (confirms persistence)

## Health / server

- [ ] `curl -s http://127.0.0.1:8787/health` → `{"ok":true}`

## Plugin + greeting

- [ ] Start Claude Code with the plugin:
      `claude --plugin-dir /Users/sydney/workspace/privat/vloude/plugin`
      (inside a tmux pane, so `$TMUX_PANE` is set)
- [ ] Run `/vloude:voice`
- [ ] Hear a random "Ich bin bereit" greeting; the session appears in the menu-bar panel

## End-to-end turn

- [ ] Start music/video in YouTube or Spotify
- [ ] Ask Claude something; let the turn finish (Claude ends with a `<speak>…</speak>` line)
- [ ] Media **pauses** just before Vloude speaks
- [ ] Hear the spoken summary, then a short **beep**
- [ ] Speak a reply; ~1.2 s of silence ends the recording (menu-bar status: listening → transcribing)
- [ ] Your transcribed reply is **typed into the same tmux pane** and submitted (Enter)
- [ ] Media **resumes** after the reply is injected

## Multi-instance / queue

- [ ] Have two Claude Code sessions (two panes) both in voice mode finish turns close together
- [ ] Vloude speaks them **one at a time** (FIFO); each reply lands in its own pane (routed by `$TMUX_PANE`)

## No-pane fallback

- [ ] Run a voice session **outside** tmux (empty `$TMUX_PANE`)
- [ ] Vloude speaks the summary but skips injection (logs "speak-only"); it does not crash
