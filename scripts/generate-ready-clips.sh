#!/usr/bin/env bash
# Pre-render ~10 varied "Ich bin bereit" clips via ElevenLabs into the app's SPM
# resources so /ready can play one instantly without a network round-trip.
# Skips gracefully (exit 0) when no API key is set — the loop can run without it.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/app/Sources/Vloude/Resources/ready"
mkdir -p "$out"

key="${ELEVENLABS_API_KEY:-}"
voice="${ELEVENLABS_VOICE_ID:-}"
if [ -z "$key" ] || [ -z "$voice" ]; then
  echo "generate-ready-clips: ELEVENLABS_API_KEY / ELEVENLABS_VOICE_ID not set — skipping (this is fine)."
  exit 0
fi

phrases=(
  "Ich bin bereit."
  "Bereit, leg los."
  "Ich höre."
  "Alles klar, ich bin da."
  "Bereit wenn du bist."
  "Sag an."
  "Ich bin ganz Ohr."
  "Bereit für die nächste Runde."
  "Los geht's."
  "Ich warte auf dich."
)

i=0
for phrase in "${phrases[@]}"; do
  fname="$(printf '%s/ready_%02d.pcm' "$out" "$i")"
  curl -sS -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/${voice}/stream?output_format=pcm_24000" \
    -H "xi-api-key: ${key}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$phrase" '{text:$t, model_id:"eleven_flash_v2_5"}')" \
    -o "$fname"
  echo "wrote $fname ($phrase)"
  i=$((i + 1))
done

echo "generate-ready-clips: done ($i clips)."
