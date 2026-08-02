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

# Claude Code and Codex send different Stop-hook envelopes. Codex requires valid
# JSON on stdout even when the hook has nothing to do; Claude treats empty stdout
# as success. Keep one script so both clients share extraction and /turn behavior.
is_codex=false
if printf '%s' "$input" | jq -e '.hook_event_name == "Stop"' >/dev/null 2>&1; then
  is_codex=true
fi

finish() {
  [ "$is_codex" = true ] && printf '{}\n'
  exit 0
}

# Host resolution: 127.0.0.1 everywhere (macOS, native Git Bash, WSL2 mirrored
# networking). Under WSL NAT mode the Windows host is reachable via the default
# gateway instead — fall back to it when loopback doesn't answer.
HOST="127.0.0.1"
if [ -n "${WSL_DISTRO_NAME:-}" ] && ! curl -sS --max-time 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  [ -n "$gw" ] && HOST="$gw"
fi

# Two spoken tags:
#   <speak>…</speak>          → speak, then LISTEN for the user's reply (normal turn).
#   <speak-end>…</speak-end>  → speak only, DON'T listen (closing line, or "I started a
#                               background task and will report back myself").
# Pick the LAST COMPLETE tag block by position — so the real final directive wins and the
# same tag mentioned earlier in prose (e.g. a `<speak-end>` example in backticks) is ignored.
# Only <speak> gets the tolerant "forgotten closing tag" fallback; <speak-end> must be closed
# (an unclosed one would otherwise swallow the rest of the message).
# The real directive is always the LAST line of the message, so the LAST opening tag by
# position is the one that counts — any earlier tag in prose (even a bare unclosed
# `<speak>` in backticks) is ignored. Extract that tag's content to its close, or to end
# of message if the close was forgotten.
msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || true)"
parsed="$(printf '%s' "$msg" | perl -0777 -ne '
  my $m = $_;
  my $sepos = -1; while ($m =~ /<speak-end>/g) { $sepos = $-[0]; }
  my $sppos = -1; while ($m =~ /<speak>/g)     { $sppos = $-[0]; }
  my ($text, $listen);
  if ($sepos >= 0 && $sepos > $sppos) {
    substr($m, $sepos) =~ /<speak-end>(.*?)(?:<\/speak-end>|\z)/s; $text = $1; $listen = "false";
  } elsif ($sppos >= 0) {
    substr($m, $sppos) =~ /<speak>(.*?)(?:<\/speak>|\z)/s; $text = $1; $listen = "true";
  }
  if (defined $text) { $text =~ s/^\s+|\s+$//g; print "$listen\n$text"; }
')"
listen="$(printf '%s' "$parsed" | head -1)"
speak="$(printf '%s' "$parsed" | tail -n +2)"

[ -z "$speak" ] && finish
[ "$listen" = "false" ] || listen=true

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

# Blocks while the turn is queued + spoken + recorded + transcribed. With many parallel
# projects a turn can wait long in the queue before it is its turn to
# speak, so allow up to an hour — the user is expected to reply eventually. hooks.json
# timeout must be >= this.
resp="$(curl -sS --max-time 3600 -X POST "http://${HOST}:${PORT}/turn" \
  -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"

transcript="$(printf '%s' "$resp" | jq -r '.transcript // ""' 2>/dev/null || true)"
transcript="$(printf '%s' "$transcript" | perl -0777 -pe 's/^\s+|\s+$//g')"
park="$(printf '%s' "$resp" | jq -r '.park // false' 2>/dev/null || echo false)"
wait_s="$(printf '%s' "$resp" | jq -r '.wait // 0' 2>/dev/null || echo 0)"

# Feed a voice reply back into the session as the next user turn, then end this hook.
inject() {
  jq -n --arg r "$1" \
    '{decision:"block", reason:$r, systemMessage:"🎙️ Parley: Sprachantwort eingespeist"}'
  exit 0
}
# "Warte X Minuten" — the app asked us to pause, then continue. Sleep, then inject the
# resume prompt so Claude picks up on its own. (hooks.json timeout must exceed the wait.)
if [ "${wait_s:-0}" -gt 0 ] 2>/dev/null; then
  resume="$(printf '%s' "$resp" | jq -r '.resume // ""' 2>/dev/null || true)"
  sleep "$wait_s"
  inject "$resume"
fi

[ -n "$transcript" ] && inject "$transcript"

# No reply. Unless the app asked to PARK this session, end normally.
[ "$park" = "true" ] || finish

# PARKED — the conversation is paused but stays resumable. Keep this Stop hook alive by
# short-polling /wake: because the hook never returns, Claude Code treats the turn as
# unfinished and the session stays live with NO keystrokes. When the user resumes it
# (by voice from another session, or the tray/menu), /wake hands back the next
# instruction, which we inject as the next turn. A curl failure means the app is gone ->
# end. hooks.json timeout caps the total park window.
wpayload="$(jq -n \
  --arg session_id "$session_id" --arg cwd "$cwd" --arg project "$project" \
  --arg tmux_pane "${TMUX_PANE:-}" --arg label "$label" \
  '{session_id:$session_id, cwd:$cwd, project:$project, tmux_pane:$tmux_pane, label:$label}')"
while true; do
  wresp="$(curl -fsS --max-time 20 -X POST "http://${HOST}:${PORT}/wake" \
    -H 'Content-Type: application/json' -d "$wpayload" 2>/dev/null)" || finish
  wtext="$(printf '%s' "$wresp" | jq -r '.transcript // ""' 2>/dev/null || true)"
  wtext="$(printf '%s' "$wtext" | perl -0777 -pe 's/^\s+|\s+$//g')"
  [ -n "$wtext" ] && inject "$wtext"
  sleep 3
done
