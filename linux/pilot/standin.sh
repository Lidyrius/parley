#!/usr/bin/env bash
# A stand-in for a Claude Code session, for testing the Linux host while Claude Code is not
# logged in on the server:  PARLEY_CLAUDE_CMD=<this file> parley run
#
# It speaks the session side of the contract over HTTP, as the parley-ui mod and the Stop hook do
# (CONTRACT.md, docs/HOOKLESS.md): a /presence heartbeat every 2 s from its folder, on which the
# host hands it instructions (a /dispatch waiting for the folder, a phone's `say`, a
# Wiedervorlage) — printed here. After the first one it "ends its turn" once like the Stop hook:
# POST /turn with a <speak> line, held open until the host answers.
# Arguments are what the host passes to claude ([--resume <id>] /parley:voice) — only shown.
set -u
B="http://127.0.0.1:${PARLEY_PORT:-8787}"
cwd="$PWD"
project="$(basename "$cwd")"
sid="$(cat /proc/sys/kernel/random/uuid)"
label=""
[ -f "$cwd/.parley.json" ] && label="$(jq -r '.name // ""' "$cwd/.parley.json" 2>/dev/null || true)"
say() { printf '%s [standin %s] %s\n' "$(date +%H:%M:%S)" "$project" "$*"; }
post() { curl -sS --max-time "$1" -X POST "$B$2" -H 'Content-Type: application/json' -d "$3" 2>/dev/null; }

# For the start check: questions in <folder>/.standin-ask (one a line) are asked on the terminal
# before anything else — as a tool's prompt at startup would hold a real session.
if [ -f "$cwd/.standin-ask" ]; then
  while IFS= read -r question <&3; do
    printf '%s ' "$question"
    read -r reply
    say "answered: $reply"
  done 3< "$cwd/.standin-ask"
fi

say "session $sid in $cwd (started with: $*)"
turned=0
while true; do
  presence="$(jq -nc --arg s "$sid" --arg c "$cwd" --arg p "$project" --arg l "$label" \
    '{session_id:$s, cwd:$c, project:$p, label:$l, state:"idle"}')"
  instruction="$(post 5 /presence "$presence" | jq -r '.instruction // ""' 2>/dev/null || true)"
  if [ -n "$instruction" ]; then
    say "INSTRUCTION: $instruction"
    if [ "$turned" = 0 ]; then
      turned=1
      turn="$(jq -nc --arg s "$sid" --arg c "$cwd" --arg p "$project" --arg l "$label" --arg t "${TMUX_PANE:-}" \
        '{event:"turn", session_id:$s, cwd:$c, project:$p, tmux_pane:$t, label:$l, listen:true,
          speak:"Stand-in hier. Die Anweisung ist angekommen — wie soll ich weitermachen, Sir?"}')"
      say "POST /turn (<speak>, long-poll) …"
      # In the background: the heartbeat goes on while the host rings, speaks and listens.
      ( reply="$(post 3600 /turn "$turn")"; say "/turn answered: ${reply:-nothing}" ) &
    fi
  fi
  sleep 2
done
