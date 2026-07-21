#!/usr/bin/env bash
# Parley terminal onboarding. Asks for API keys, language, voice and microphone,
# writes them to the app's credential store, and marks onboarding complete — so a
# Claude Code session can use /parley:voice immediately. Uses `gum` for a nicer TUI
# when available, otherwise plain bash prompts. No non-stdlib deps required.
set -euo pipefail

# When invoked via `curl … | bash`, stdin is the pipe (already at EOF), so read/select
# would spin on EOF. Reconnect stdin to the controlling terminal for the interactive TUI.
[ -t 0 ] || { [ -e /dev/tty ] && exec < /dev/tty; } || {
  echo "Keine interaktive Terminal-Eingabe verfügbar. Führe die Einrichtung manuell aus:" >&2
  echo "  bash $0" >&2
  exit 1
}

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
EXIST_GOOGLE="$(jq -r '.googleAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"
EXIST_GROQ="$(jq -r '.groqAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"

say "1/4 · Google Cloud TTS API-Key (Sprachausgabe)"
note "Cloud Text-to-Speech aktivieren, dann API-Key erstellen. Erste 1 Mio Zeichen/Monat gratis."
if [ -n "$EXIST_GOOGLE" ] && [ "$(pick "Vorhandenen Google-Key behalten?" "Ja" "Neu eingeben")" = "Ja" ]; then
  GOOGLE="$EXIST_GOOGLE"
else
  GOOGLE="$(ask_secret "Google TTS API-Key")"
fi

say "2/4 · Groq API-Key (Transkription)"
if [ -n "$EXIST_GROQ" ] && [ "$(pick "Vorhandenen Groq-Key behalten?" "Ja" "Neu eingeben")" = "Ja" ]; then
  GROQ="$EXIST_GROQ"
else
  GROQ="$(ask_secret "Groq bearer key")"
fi

# --- Language --- (name → BCP-47 code for the TTS voice)
say "3/4 · Sprache"
LANG_NAME="$(pick "Gesprochene Sprache" "Deutsch" "English" "Français" "Español" "Italiano" "Nederlands")"
case "$LANG_NAME" in
  Deutsch)    LANG_CODE="de-DE" ;; English) LANG_CODE="en-US" ;;
  Français)   LANG_CODE="fr-FR" ;; Español) LANG_CODE="es-ES" ;;
  Italiano)   LANG_CODE="it-IT" ;; Nederlands) LANG_CODE="nl-NL" ;;
  *)          LANG_CODE="de-DE" ;;
esac

# --- Voice (Chirp3 HD voices for the chosen language) --- (bash 3.2 safe)
say "4a · Stimme"
GOOGLE_VOICE="$LANG_CODE-Chirp3-HD-Alnilam"   # default
if [ -n "$GOOGLE" ]; then
  VJSON="$(curl -fsS -H "X-Goog-Api-Key: $GOOGLE" \
    "https://texttospeech.googleapis.com/v1/voices?languageCode=$LANG_CODE" 2>/dev/null || echo '')"
  if [ -n "$VJSON" ]; then
    VNAMES=(); VFULL=()
    # Show the star-name suffix (e.g. "Alnilam"); store the full voice id.
    while IFS=$'\t' read -r short full; do [ -n "$short" ] && { VNAMES+=("$short"); VFULL+=("$full"); }; done \
      < <(printf '%s' "$VJSON" | jq -r '.voices[] | select(.name|test("Chirp3-HD")) | "\(.name|sub(".*Chirp3-HD-";""))\t\(.name)"' | sort)
    if [ "${#VNAMES[@]}" -gt 0 ]; then
      CHOSEN="$(pick "Welche Chirp3-HD-Stimme?" "${VNAMES[@]}")"
      for i in "${!VNAMES[@]}"; do [ "${VNAMES[$i]}" = "$CHOSEN" ] && GOOGLE_VOICE="${VFULL[$i]}"; done
    fi
  else
    note "Konnte Stimmen nicht laden — nutze Standard (Alnilam)."
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

# --- Persist --- (merge onto existing creds so any ElevenLabs fallback keys survive)
mkdir -p "$CREDS_DIR"; chmod 700 "$CREDS_DIR"
BASE="$(cat "$CREDS" 2>/dev/null || echo '{}')"
printf '%s' "$BASE" | jq \
  --arg gk "$GOOGLE" --arg gv "$GOOGLE_VOICE" --arg g "$GROQ" --arg l "$LANG_NAME" --arg m "${MIC_UID:-}" \
  '. + {googleAPIKey:$gk, googleVoice:$gv, groqAPIKey:$g, language:$l, micDeviceUID:$m}' > "$CREDS"
chmod 600 "$CREDS"

# Media control now uses MediaRemote (no Accessibility needed) — no gate.
[ -n "$BIN" ] && "$BIN" --mark-onboarded >/dev/null 2>&1 || true

say "Fertig ✓"
note "Sprache: $LANG_NAME · Stimme: $GOOGLE_VOICE"
note "Starte eine Claude-Code-Sitzung und tippe /parley:voice."
