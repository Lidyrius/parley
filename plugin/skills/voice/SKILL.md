---
name: voice
description: Turn on Vloude voice-conversation mode for this session. Invoke when the user says /vloude:voice, "voice mode", "talk to me", "sprich mit mir", or wants spoken turn summaries and voice replies.
disable-model-invocation: true
---

# Vloude voice mode

Invoking this skill puts THIS session into voice-conversation mode. Two things happen: wake+greet the desktop app now, then speak at the end of every turn from here on.

## 1. Wake and greet the app (do this once, right now)

Run this bash command exactly once:

```bash
open -a Vloude 2>/dev/null; sleep 1; curl -s --max-time 3 -X POST http://127.0.0.1:8787/ready -H 'Content-Type: application/json' -d "$(jq -n --arg tmux_pane "${TMUX_PANE:-}" --arg cwd "$PWD" --arg project "$(basename "$PWD")" '{event:"ready",tmux_pane:$tmux_pane,cwd:$cwd,project:$project}')" >/dev/null 2>&1; echo "vloude armed"
```

Then tell the user in one short line that voice mode is on.

## 2. Speak at the end of EVERY turn (for the rest of this session)

End every response — including this one — with a single spoken line wrapped in `<speak>…</speak>`:

- 1–2 sentences, written to be **heard**, not read: plain spoken language, no markdown, no code, no file paths, no lists.
- Say what you just did, any problem you hit, and what's next.
- If you need the user's input or a decision, end with a direct question. If you're just reporting and continuing, don't force a question.
- Keep it under ~40 words. This is the ONLY thing the app speaks aloud; the rest of your response stays on screen as normal.

Example ending:
```
<speak>Die Tests sind grün und die API ist deployed. Soll ich das Log-Level noch auf Warning senken, oder passt das so?</speak>
```

The app extracts the `<speak>` text, speaks it, then records the user's voice reply and types it back into this session automatically. So after a `<speak>` line that asks a question, just wait — the next user message will arrive as if typed.

Voice mode stays on until the session ends. Do not mention the `<speak>` tag to the user in your visible prose; just include it at the very end.
