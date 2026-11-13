#!/usr/bin/env bash
# Pilot helpers for the Linux host, run on the server from the repo root:
#   linux/pilot/pilot.sh start                      the daemon in tmux session `parley`; sessions are stand-ins (standin.sh)
#   linux/pilot/pilot.sh stop | log [n] | status
#   linux/pilot/pilot.sh dispatch <folder> <text>   POST /dispatch (the folder is made when missing)
#   linux/pilot/pilot.sh pane <tmux session> [n]    a session's screen
#   linux/pilot/pilot.sh remind <to> <text> <sec>   POST /remind, due in <sec> seconds
#   linux/pilot/pilot.sh sim [sim-phone options]    pair, then a stand-in phone on the relay — the
#                                                   pairing link (a secret) is never printed
#   linux/pilot/pilot.sh roundtrip "<reply>" [sec]  one voice turn end to end with a stand-in session: it is
#                                                   dispatched, rings, the stand-in phone answers, hears the
#                                                   host's voice (~/parley-host-voice.wav) and says <reply>
# Before `start`: PARLEY_CLAUDE_CMD runs something else than the stand-in (e.g. claude);
# PARLEY_CALLBACK_WAIT_SECONDS shortens the 30 min an unanswered ring waits for a call back.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PARLEY="dotnet $REPO/linux/bin/Release/net8.0/parley.dll"
B="http://127.0.0.1:8787"
post() { curl -sS --max-time 10 -X POST "$B$1" -H 'Content-Type: application/json' -d "$2"; echo; }

case "${1:-}" in
  start)
    tmux kill-session -t '=parley' 2>/dev/null || true
    tmux new-session -d -s parley -x 200 -y 50 \
      "PARLEY_CLAUDE_CMD='${PARLEY_CLAUDE_CMD:-$REPO/linux/pilot/standin.sh}' PARLEY_CALLBACK_WAIT_SECONDS='${PARLEY_CALLBACK_WAIT_SECONDS:-}' $PARLEY run"
    for _ in $(seq 1 40); do curl -fsS --max-time 1 "$B/health" 2>/dev/null && break; sleep 0.5; done
    echo
    ;;
  stop) tmux kill-session -t '=parley' ;;
  log) tail -n "${2:-40}" "${XDG_CONFIG_HOME:-$HOME/.config}/Parley/debug.log" ;;
  status) $PARLEY status ;;
  dispatch)
    mkdir -p "$2"
    post /dispatch "$(jq -nc --arg c "$2" --arg i "$3" '{cwd:$c, instruction:$i, start:true}')"
    ;;
  pane) tmux capture-pane -p -t "=$2:" | grep -v '^[[:space:]]*$' | tail -n "${3:-15}" ;;
  remind)
    post /remind "$(jq -nc --arg to "$2" --arg text "$3" --arg at "$(date -d "+$4 seconds" +%Y-%m-%dT%H:%M:%S%:z)" '{to:$to, text:$text, at:$at}')"
    ;;
  sim)
    shift
    link="$($PARLEY pair 2>/dev/null)"
    sleep 4   # the daemon notices the room within 2 s and opens it
    $PARLEY sim-phone "$link" "$@"
    ;;
  roundtrip)
    reply="${2:?what the phone says}"
    name="pilot-rt-$(date +%H%M%S)"
    dir="$HOME/workspace/privat/$name"
    out="$(mktemp)"
    link="$($PARLEY pair 2>/dev/null)"
    sleep 4
    # The phone first (it must be in the room when the session's turn rings), then the session.
    $PARLEY sim-phone "$link" --seconds "${3:-180}" --mic-say "$reply" --save "$HOME/parley-host-voice.wav" > "$out" 2>&1 &
    sim=$!
    until grep -q 'in the room' "$out" || ! kill -0 "$sim" 2>/dev/null; do sleep 0.5; done
    code=0
    if kill -0 "$sim" 2>/dev/null; then
      mkdir -p "$dir"
      post /dispatch "$(jq -nc --arg c "$dir" '{cwd:$c, instruction:"Pilot: ein Sprachzug bitte.", start:true}')"
      wait "$sim" || code=$?
      sleep 2   # the session prints the answer to its /turn
    else
      wait "$sim" || code=$?
    fi
    echo "--- the phone (sim-phone, exit $code)"; cat "$out"; rm -f "$out"
    if [ -d "$dir" ]; then
      echo "--- the session ($name): its /turn answer carries the transcript"
      "$0" pane "parley-$name" 8 || true
      echo "--- the host's log"
      "$0" log 60 | sed -n "/project=$name/,\$p" | grep -vE 'relay: |phone: hello' || true
      post /close "$(jq -nc --arg p "$name" '{project:$p}')" >/dev/null || true
      rm -rf "$dir"
    fi
    exit "$code"
    ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
