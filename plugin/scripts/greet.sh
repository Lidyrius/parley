#!/usr/bin/env bash
# Wake the Parley app and send a /ready greeting. Fire-and-forget.
set -euo pipefail
PORT="${PARLEY_PORT:-8787}"

# Launch app if a bundle is installed; harmless if already running or not bundled.
open -a Parley >/dev/null 2>&1 || true
# Give a cold launch a moment to bind the port.
for _ in 1 2 3 4 5 6; do
  curl -sS --max-time 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
  sleep 0.5
done

payload="$(jq -n \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg cwd "$PWD" \
  --arg project "$(basename "$PWD")" \
  '{event:"ready", tmux_pane:$tmux_pane, cwd:$cwd, project:$project}')"

if curl -sS --max-time 3 -X POST "http://127.0.0.1:${PORT}/ready" \
     -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
  echo "parley: armed (app reachable on :${PORT})"
else
  echo "parley: WARNING — app not reachable on :${PORT}. Start it: ./app/.build/release/Parley"
fi

# Report the user's configured spoken-turn language so the command instructs Claude to
# speak in it. Default Deutsch. Source: the app's credential store.
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
LANG_NAME="Deutsch"
if [ -f "$CREDS" ]; then
  LANG_NAME="$(jq -r '.language // "Deutsch"' "$CREDS" 2>/dev/null || echo Deutsch)"
fi
echo "PARLEY_LANGUAGE=${LANG_NAME}"

# Spoken project name from <project>/.parley.json (empty → the skill asks the user once).
PROJECT_NAME=""
[ -f "$PWD/.parley.json" ] && PROJECT_NAME="$(jq -r '.name // ""' "$PWD/.parley.json" 2>/dev/null || echo "")"
echo "PARLEY_PROJECT_NAME=${PROJECT_NAME}"
