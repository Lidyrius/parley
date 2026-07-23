#!/usr/bin/env bash
# Wake the Parley app and send a /ready greeting. Fire-and-forget.
set -euo pipefail
PORT="${PARLEY_PORT:-8787}"

# Reachable host for the app. Loopback works on macOS, native Windows, and WSL2
# mirrored networking. WSL2 NAT is handled by a gateway fallback further down.
HOST="127.0.0.1"

# Launch the app if it isn't already answering. Cross-platform, harmless if running.
if ! curl -sS --max-time 1 "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    # WSL: start the Windows-side Parley.exe (macOS `open` does not exist here).
    # Detach from all stdio, else the launched GUI app inherits our stdout pipe
    # and the caller blocks until EOF (never comes while the app runs).
    win_exe="$(ls /mnt/c/Users/*/AppData/Local/Parley/Parley.exe 2>/dev/null | head -1 || true)"
    [ -n "$win_exe" ] && ( setsid cmd.exe /c start "" "$(wslpath -w "$win_exe")" </dev/null >/dev/null 2>&1 & ) || true
  elif command -v open >/dev/null 2>&1; then
    open -a Parley >/dev/null 2>&1 || true                                 # macOS
  elif [ -n "${LOCALAPPDATA:-}" ]; then
    ( cd "$LOCALAPPDATA/Parley" && cmd.exe /c start "" Parley.exe ) </dev/null >/dev/null 2>&1 || true  # Git Bash
  fi
fi

# Give a cold launch a moment to bind the port. Under WSL2 NAT (non-mirrored) the
# app is only reachable via the default gateway, so probe that as a fallback.
for _ in 1 2 3 4 5 6 7 8; do
  curl -sS --max-time 1 "http://${HOST}:${PORT}/health" >/dev/null 2>&1 && break
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
    if [ -n "$gw" ] && curl -sS --max-time 1 "http://${gw}:${PORT}/health" >/dev/null 2>&1; then
      HOST="$gw"; break
    fi
  fi
  sleep 0.5
done

payload="$(jq -n \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg cwd "$PWD" \
  --arg project "$(basename "$PWD")" \
  '{event:"ready", tmux_pane:$tmux_pane, cwd:$cwd, project:$project}')"

if curl -sS --max-time 3 -X POST "http://${HOST}:${PORT}/ready" \
     -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
  echo "parley: armed (app reachable on :${PORT})"
else
  echo "parley: WARNING — app not reachable on :${PORT}. Start it: ./app/.build/release/Parley"
fi

# Report the user's configured spoken-turn language so the command instructs Claude to
# speak in it. Default Deutsch. Source: the app's credential store — macOS path first,
# then Windows (Git Bash %APPDATA%), then WSL (/mnt/c).
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
[ -f "$CREDS" ] || CREDS="${APPDATA:-/nonexistent}/Parley/credentials.json"
[ -f "$CREDS" ] || CREDS="$(ls /mnt/c/Users/*/AppData/Roaming/Parley/credentials.json 2>/dev/null | head -1 || true)"
LANG_NAME="Deutsch"
if [ -f "$CREDS" ]; then
  LANG_NAME="$(jq -r '.language // "Deutsch"' "$CREDS" 2>/dev/null || echo Deutsch)"
fi
echo "PARLEY_LANGUAGE=${LANG_NAME}"

# Spoken project name from <project>/.parley.json (empty → the skill asks the user once).
PROJECT_NAME=""
[ -f "$PWD/.parley.json" ] && PROJECT_NAME="$(jq -r '.name // ""' "$PWD/.parley.json" 2>/dev/null || echo "")"
echo "PARLEY_PROJECT_NAME=${PROJECT_NAME}"
