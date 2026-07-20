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

# In-character Jarvis lines: dry, polite, British-butler AI addressing the user as "Sir".
phrases=(
  "Zu Diensten, Sir. Ich bin bereit."
  "Systeme hochgefahren. Ich stehe bereit, Sir."
  "Bereit, wann immer Sie es sind, Sir."
  "Ganz zu Ihren Diensten. Womit fangen wir an?"
  "Ich bin online, Sir. Sagen Sie an."
  "Bereit und wartend, Sir."
  "Alles bereit. Ich höre, Sir."
  "Zu Ihren Diensten. Was steht an, Sir?"
  "Ich bin da, Sir. Legen wir los."
  "Bereit für die nächste Aufgabe, Sir."
)

i=0
for phrase in "${phrases[@]}"; do
  fname="$(printf '%s/ready_%02d.pcm' "$out" "$i")"
  code=$(curl -sS -w '%{http_code}' -o "$fname" -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/${voice}/stream?output_format=pcm_24000" \
    -H "xi-api-key: ${key}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$phrase" '{text:$t, model_id:"eleven_flash_v2_5", voice_settings:{stability:0.45, similarity_boost:0.85, style:0.3, use_speaker_boost:true}}')")
  if [ "$code" != "200" ]; then
    echo "ERROR: clip $i failed (HTTP $code): $(cat "$fname")"; rm -f "$fname"; exit 1
  fi
  echo "wrote $fname ($phrase)"
  i=$((i + 1))
done

echo "generate-ready-clips: done ($i clips)."
