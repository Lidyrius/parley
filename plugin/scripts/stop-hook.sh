#!/usr/bin/env bash
# Parley Stop hook (terminal-agnostic voice loop).
#
# 1. Extract the <speak>…</speak> line from the last assistant message.
#    No tag  -> voice mode is off / nothing to say -> exit 0 (session ends normally).
# 2. LONG-POLL the app: POST /turn. The app speaks the line, records the user's voice
#    reply, transcribes it, and returns {"transcript":"..."} once the user stops talking.
# 3. Empty transcript (silence / app down) -> exit 0 (end the conversation).
#    Otherwise emit {"decision":"block","reason":<transcript>} so Claude Code feeds the
#    spoken reply back into THIS session as the next turn — no tmux, no keystrokes,
#    works in Warp / iTerm / any terminal.
set -euo pipefail

PORT="${PARLEY_PORT:-8787}"
input="$(cat)"

# Two spoken tags:
#   <speak>…</speak>          → speak, then LISTEN for the user's reply (normal turn).
#   <speak-end>…</speak-end>  → speak only, DON'T listen (closing line, or "I started a
#                               background task and will report back myself").
# A response carries exactly one. Prefer <speak-end> if present; else <speak>. The greedy
# `.*` prefix takes the LAST block; the closing tag is optional (forgotten → take to end).
msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // ""')"
speak="$(printf '%s' "$msg" | perl -0777 -ne 'print $1 if /.*<speak-end>(.*?)(?:<\/speak-end>|\z)/s' | perl -0777 -pe 's/^\s+|\s+$//g')"
listen=false
if [ -z "$speak" ]; then
  speak="$(printf '%s' "$msg" | perl -0777 -ne 'print $1 if /.*<speak>(.*?)(?:<\/speak>|\z)/s' | perl -0777 -pe 's/^\s+|\s+$//g')"
  listen=true
fi

[ -z "$speak" ] && exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""')"
project="$(basename "${cwd:-unknown}")"

# Optional per-project config: <project>/.parley.json → { "name": "<spoken label>" }.
# Used to announce which project is speaking when multiple run in parallel.
label=""
[ -f "$cwd/.parley.json" ] && label="$(jq -r '.name // ""' "$cwd/.parley.json" 2>/dev/null || echo "")"

payload="$(jq -n \
  --arg event "turn" \
  --arg session_id "$session_id" \
  --arg cwd "$cwd" \
  --arg project "$project" \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg speak "$speak" \
  --arg label "$label" \
  --argjson listen "$listen" \
  '{event:$event, session_id:$session_id, cwd:$cwd, project:$project, tmux_pane:$tmux_pane, speak:$speak, label:$label, listen:$listen}')"

# Blocks while the app speaks + records + transcribes. Must exceed the app's max
# recording cap (90 s) + speak + STT; the hook timeout (hooks.json) in turn exceeds this.
resp="$(curl -sS --max-time 140 -X POST "http://127.0.0.1:${PORT}/turn" \
  -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"

transcript="$(printf '%s' "$resp" | jq -r '.transcript // ""' 2>/dev/null || true)"
transcript="$(printf '%s' "$transcript" | perl -0777 -pe 's/^\s+|\s+$//g')"

# No reply -> let the session end.
[ -z "$transcript" ] && exit 0

# Feed the voice reply back into the session as the next user turn.
jq -n --arg r "$transcript" \
  '{decision:"block", reason:$r, systemMessage:"🎙️ Parley: Sprachantwort eingespeist"}'
exit 0
