#!/usr/bin/env bash
# Vloude Stop hook (terminal-agnostic voice loop).
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

PORT="${VLOUDE_PORT:-8787}"
input="$(cat)"

# Extract the LAST <speak>…</speak> block. The greedy `.*` prefix consumes any earlier
# <speak> mentions (e.g. from quoted file content the assistant read), so we always get
# the intended final spoken line, never a span across the whole message.
speak="$(printf '%s' "$input" \
  | jq -r '.last_assistant_message // ""' \
  | perl -0777 -ne 'print $1 if /.*<speak>(.*?)<\/speak>/s' \
  | perl -0777 -pe 's/^\s+|\s+$//g')"

[ -z "$speak" ] && exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""')"
project="$(basename "${cwd:-unknown}")"

payload="$(jq -n \
  --arg event "turn" \
  --arg session_id "$session_id" \
  --arg cwd "$cwd" \
  --arg project "$project" \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg speak "$speak" \
  '{event:$event, session_id:$session_id, cwd:$cwd, project:$project, tmux_pane:$tmux_pane, speak:$speak}')"

# Blocks while the app speaks + records + transcribes (bounded by the app's own caps).
resp="$(curl -sS --max-time 120 -X POST "http://127.0.0.1:${PORT}/turn" \
  -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"

transcript="$(printf '%s' "$resp" | jq -r '.transcript // ""' 2>/dev/null || true)"
transcript="$(printf '%s' "$transcript" | perl -0777 -pe 's/^\s+|\s+$//g')"

# No reply -> let the session end.
[ -z "$transcript" ] && exit 0

# Feed the voice reply back into the session as the next user turn.
jq -n --arg r "$transcript" \
  '{decision:"block", reason:$r, systemMessage:"🎙️ Vloude: Sprachantwort eingespeist"}'
exit 0
