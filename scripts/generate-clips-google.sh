#!/usr/bin/env bash
# Regenerate ALL cached clips (greeting + per-intent ack lines) with Google Cloud TTS
# (Chirp3 HD). Phrase text comes from the language template that matches the chosen
# voice's language (scripts/clip-texts/<code>.txt), so the cached audio is in the same
# language + voice as the live turns. Reads key/voice from GOOGLE_TTS_* env or the app's
# credential store. bash 3.2 safe. Shows a progress bar on stderr.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
KEY="${GOOGLE_TTS_API_KEY:-$(jq -r '.googleAPIKey // ""' "$CREDS" 2>/dev/null || echo "")}"
VOICE="${GOOGLE_TTS_VOICE:-$(jq -r '.googleVoice // "de-DE-Chirp3-HD-Alnilam"' "$CREDS" 2>/dev/null || echo "de-DE-Chirp3-HD-Alnilam")}"
[ -n "$VOICE" ] || VOICE="de-DE-Chirp3-HD-Alnilam"
LANG="$(printf '%s' "$VOICE" | cut -d- -f1-2)"

if [ -z "$KEY" ]; then echo "generate-clips-google: no Google TTS key — skipping."; exit 0; fi

TEMPLATE="$here/scripts/clip-texts/$LANG.txt"
[ -f "$TEMPLATE" ] || TEMPLATE="$here/scripts/clip-texts/de-DE.txt"   # fall back to German text
[ -f "$TEMPLATE" ] || { echo "generate-clips-google: no template for $LANG"; exit 1; }

TOTAL="$(grep -c '|' "$TEMPLATE" || echo 0)"
DONE=0
progress() { # draw the bar on stderr (install shows it; keeps stdout clean)
  local w=24 filled i bar=""
  filled=$(( TOTAL > 0 ? DONE * w / TOTAL : 0 ))
  for ((i=0;i<w;i++)); do [ "$i" -lt "$filled" ] && bar="$bar#" || bar="$bar-"; done
  printf '\r  [%s] %d/%d Clips (%s)' "$bar" "$DONE" "$TOTAL" "$VOICE" >&2
}

synth() { # text outfile — retries on transient non-200 (e.g. 403 during API propagation)
  local text="$1" out="$2" tmp code try
  tmp="$(mktemp).wav"
  for try in 1 2 3 4 5 6; do
    code=$(curl -sS -w '%{http_code}' -o "$tmp.json" -X POST \
      "https://texttospeech.googleapis.com/v1/text:synthesize" \
      -H "X-Goog-Api-Key: $KEY" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$text" --arg v "$VOICE" --arg l "$LANG" \
        '{input:{text:$t},voice:{languageCode:$l,name:$v},audioConfig:{audioEncoding:"LINEAR16",sampleRateHertz:24000}}')")
    [ "$code" = "200" ] && break
    printf '\n  retry %s (%s): %s\n' "$try" "$code" "$text" >&2; sleep 5
  done
  if [ "$code" != "200" ]; then printf '\nERROR (%s) for: %s\n' "$code" "$text" >&2; jq -r '.error.message // .' "$tmp.json" | head -1 >&2; rm -f "$tmp" "$tmp.json"; exit 1; fi
  jq -r '.audioContent' "$tmp.json" | base64 -D > "$tmp"
  tail -c +45 "$tmp" > "$out"          # strip 44-byte WAV header → raw pcm_24000
  rm -f "$tmp" "$tmp.json"
  DONE=$((DONE+1)); progress
}

ready_out="$here/app/Sources/Parley/Resources/ready"
lines_out="$here/app/Sources/Parley/Resources/lines"
mkdir -p "$ready_out"; rm -f "$ready_out"/*.pcm
for c in feature bug stop continue other question research feature_research bug_feature; do
  mkdir -p "$lines_out/$c"; rm -f "$lines_out/$c"/*.pcm 2>/dev/null || true
done

progress
ri=0; gi=0
while IFS='|' read -r key text; do
  [ -n "$key" ] || continue
  case "$key" in
    ready) synth "$text" "$(printf '%s/ready_%02d.pcm' "$ready_out" "$ri")"; ri=$((ri+1)) ;;
    *)     synth "$text" "$(printf '%s/%s/%s_%02d.pcm' "$lines_out" "$key" "$key" "$gi")"; gi=$((gi+1)) ;;
  esac
done < "$TEMPLATE"
printf '\n' >&2
echo "generate-clips-google: done ($DONE clips, $LANG, $VOICE)."
