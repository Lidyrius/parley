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
msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // ""')"
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

[ -z "$speak" ] && exit 0
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

# Blocks while the app speaks + records + transcribes. Must exceed the app's max
# recording cap (90 s) + speak + STT; the hook timeout (hooks.json) in turn exceeds this.
resp="$(curl -sS --max-time 140 -X POST "http://${HOST}:${PORT}/turn" \
  -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"

transcript="$(printf '%s' "$resp" | jq -r '.transcript // ""' 2>/dev/null || true)"
transcript="$(printf '%s' "$transcript" | perl -0777 -pe 's/^\s+|\s+$//g')"

# No reply -> let the session end.
[ -z "$transcript" ] && exit 0

# Feed the voice reply back into the session as the next user turn.
jq -n --arg r "$transcript" \
  '{decision:"block", reason:$r, systemMessage:"🎙️ Parley: Sprachantwort eingespeist"}'
exit 0
