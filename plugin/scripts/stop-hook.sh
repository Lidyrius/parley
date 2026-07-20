#!/usr/bin/env bash
# Vloude Stop hook: extract <speak>…</speak> from the last assistant message and
# POST it to the local Vloude app so it can speak + start the voice reply loop.
# Fire-and-forget: never block or fail the Claude turn.
set -euo pipefail

PORT="${VLOUDE_PORT:-8787}"
input="$(cat)"

speak="$(printf '%s' "$input" \
  | jq -r '.last_assistant_message // ""' \
  | perl -0777 -ne 'print $1 if /<speak>(.*?)<\/speak>/s' \
  | perl -0777 -pe 's/^\s+|\s+$//g')"

# No spoken line → nothing to do (normal for turns Claude didn't tag).
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

curl -sS --max-time 3 -X POST "http://127.0.0.1:${PORT}/turn" \
  -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true

exit 0
