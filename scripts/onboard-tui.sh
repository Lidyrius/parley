#!/usr/bin/env bash
# Parley terminal onboarding. Asks for API keys, language, voice and microphone,
# writes them to the app's credential store, and marks onboarding complete — so a
# Claude Code session can use /parley:voice immediately. Uses `gum` for a nicer TUI
# when available, otherwise plain bash prompts. No non-stdlib deps required.
set -euo pipefail

CREDS_DIR="$HOME/Library/Application Support/Parley"
CREDS="$CREDS_DIR/credentials.json"
JARVIS="JyoJov3tFx6ucWOiDwTM"

# Locate the app binary (for --list-mics / --set-mic / --mark-onboarded).
BIN="${PARLEY_BIN:-}"
for c in "$HOME/Applications/Parley.app/Contents/MacOS/Parley" \
         "/Applications/Parley.app/Contents/MacOS/Parley" \
         "$(dirname "$0")/../app/.build/release/Parley" \
         "$(dirname "$0")/../app/.build/debug/Parley"; do
  [ -z "$BIN" ] && [ -x "$c" ] && BIN="$c"
done

have() { command -v "$1" >/dev/null 2>&1; }
GUM=""; have gum && GUM=1

say()  { if [ -n "$GUM" ]; then gum style --foreground 212 "$1"; else printf '\n\033[1;35m%s\033[0m\n' "$1"; fi; }
note() { if [ -n "$GUM" ]; then gum style --foreground 244 "$1"; else printf '\033[2m%s\033[0m\n' "$1"; fi; }

ask_secret() { # prompt -> value on stdout
  if [ -n "$GUM" ]; then gum input --password --placeholder "$1"
  else read -r -s -p "$1: " v; echo >&2; printf '%s' "$v"; fi
}
pick() { # prompt then options... -> chosen option on stdout
  local prompt="$1"; shift
  if [ -n "$GUM" ]; then printf '%s\n' "$@" | gum choose --header "$prompt"
  else
    printf '%s\n' "$prompt" >&2
    select opt in "$@"; do [ -n "$opt" ] && { printf '%s' "$opt"; break; }; done
  fi
}

say "Parley — Einrichtung"
note "Deine Eingaben bleiben lokal in $CREDS (0600)."

# --- API keys (prefill from existing creds / .env if present) ---
EXIST_EL="$(jq -r '.elevenLabsAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"
EXIST_GROQ="$(jq -r '.groqAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"

say "1/4 · ElevenLabs API-Key (Sprachausgabe)"
if [ -n "$EXIST_EL" ] && [ "$(pick "Vorhandenen ElevenLabs-Key behalten?" "Ja" "Neu eingeben")" = "Ja" ]; then
  EL="$EXIST_EL"
else
  EL="$(ask_secret "ElevenLabs xi-api-key")"
fi

say "2/4 · Groq API-Key (Transkription)"
if [ -n "$EXIST_GROQ" ] && [ "$(pick "Vorhandenen Groq-Key behalten?" "Ja" "Neu eingeben")" = "Ja" ]; then
  GROQ="$EXIST_GROQ"
else
  GROQ="$(ask_secret "Groq bearer key")"
fi

# --- Language ---
say "3/4 · Sprache"
LANG_NAME="$(pick "Gesprochene Sprache" "Deutsch" "English" "Français" "Español" "Italiano" "Nederlands")"

# --- Voice (fetch from ElevenLabs) --- (bash 3.2 safe: parallel arrays, no mapfile/assoc)
say "4a · Stimme"
VOICE_ID="$JARVIS"
if [ -n "$EL" ]; then
  VJSON="$(curl -fsS -H "xi-api-key: $EL" https://api.elevenlabs.io/v1/voices 2>/dev/null || echo '')"
  if [ -n "$VJSON" ]; then
    VNAMES=(); VIDS=()
    while IFS=$'\t' read -r n id; do [ -n "$n" ] && { VNAMES+=("$n"); VIDS+=("$id"); }; done \
      < <(printf '%s' "$VJSON" | jq -r '.voices[] | "\(.name)  ⟨\(.category)⟩\t\(.voice_id)"')
    if [ "${#VNAMES[@]}" -gt 0 ]; then
      CHOSEN="$(pick "Welche Stimme?" "${VNAMES[@]}")"
      for i in "${!VNAMES[@]}"; do [ "${VNAMES[$i]}" = "$CHOSEN" ] && VOICE_ID="${VIDS[$i]}"; done
    fi
  else
    note "Konnte Stimmen nicht laden — nutze Standard (Jarvis)."
  fi
fi

# --- Microphone --- (bash 3.2 safe)
say "4b · Mikrofon"
MIC_UID=""
if [ -n "$BIN" ]; then
  MJSON="$("$BIN" --list-mics 2>/dev/null || echo '[]')"
  MNAMES=("Systemstandard"); MUIDS=("")
  while IFS=$'\t' read -r n u; do [ -n "$n" ] && { MNAMES+=("$n"); MUIDS+=("$u"); }; done \
    < <(printf '%s' "$MJSON" | jq -r '.[] | "\(.name)\t\(.uid)"')
  if [ "${#MNAMES[@]}" -gt 1 ]; then
    MCHOSEN="$(pick "Welches Mikrofon?" "${MNAMES[@]}")"
    for i in "${!MNAMES[@]}"; do
      [ "${MNAMES[$i]}" = "$MCHOSEN" ] && MIC_UID="${MUIDS[$i]}"
    done
    [ -n "$MIC_UID" ] && "$BIN" --set-mic "$MIC_UID" >/dev/null 2>&1 || true
  fi
else
  note "App-Binary nicht gefunden — Mikrofon überspringe ich (Systemstandard)."
fi

# --- Persist ---
mkdir -p "$CREDS_DIR"; chmod 700 "$CREDS_DIR"
jq -n --arg e "$EL" --arg g "$GROQ" --arg v "$VOICE_ID" --arg l "$LANG_NAME" --arg m "${MIC_UID:-}" \
  '{elevenLabsAPIKey:$e, groqAPIKey:$g, voiceID:$v, language:$l, micDeviceUID:$m}' > "$CREDS"
chmod 600 "$CREDS"

[ -n "$BIN" ] && "$BIN" --mark-onboarded >/dev/null 2>&1 || true

say "Fertig ✓"
note "Sprache: $LANG_NAME · Stimme: $VOICE_ID"
note "Starte eine Claude-Code-Sitzung und tippe /parley:voice."
