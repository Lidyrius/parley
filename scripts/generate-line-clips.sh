#!/usr/bin/env bash
# Pre-render Jarvis acknowledgement lines per intent category into the app's SPM
# resources, so after classifying the user's reply we can play one instantly.
# Skips gracefully (exit 0) without an API key. bash 3.2 safe (no assoc arrays).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/app/Sources/Parley/Resources/lines"

key="${ELEVENLABS_API_KEY:-}"
voice="${ELEVENLABS_VOICE_ID:-}"
if [ -z "$key" ] || [ -z "$voice" ]; then
  echo "generate-line-clips: no ELEVENLABS_API_KEY / VOICE_ID — skipping (fine)."
  exit 0
fi

# category|phrase — dry, polite Jarvis, addresses the user as "Sir".
lines=(
  "feature|Sehr wohl, Sir. Ich baue es ein und melde mich, sobald es fertig ist."
  "feature|Verstanden. Ich setze das um und gebe Bescheid, wenn es steht."
  "feature|Alles klar, ich mache mich an den Einbau und melde mich mit dem Ergebnis."
  "bug|Verstanden, Sir. Ich untersuche das sofort und melde mich mit einer Lösung."
  "bug|Alles klar, ich gehe dem Fehler auf den Grund und behebe ihn."
  "bug|Zu Diensten. Ich sehe mir das Problem an und melde mich, wenn es behoben ist."
  "stop|Sehr wohl, Sir. Ich halte hier an."
  "stop|Verstanden, ich stoppe und warte auf Ihre nächste Anweisung."
  "stop|Alles klar, ich pausiere."
  "continue|Gut, Sir. Ich fahre fort."
  "continue|Verstanden, ich mache weiter."
  "continue|Sehr wohl, ich setze fort, Sir."
  "other|Verstanden, Sir. Ich kümmere mich darum."
  "other|Alles klar, ich sehe mir das an."
  "other|Zu Diensten. Ich nehme mich der Sache an."
  "question|Gute Frage, Sir. Ich prüfe das kurz und habe gleich eine Antwort."
  "question|Einen Augenblick, ich sehe nach und antworte sogleich."
  "question|Lassen Sie mich das kurz prüfen, dann habe ich Ihre Antwort."
  "research|Verstanden, Sir. Ich recherchiere das kurz und melde mich."
  "research|Alles klar, ich sehe mich kurz um und berichte Ihnen."
  "research|Zu Diensten. Ich schaue mich um und komme mit Ergebnissen zurück."
  "feature_research|Sehr wohl, ich recherchiere kurz und baue das Feature dann ein."
  "feature_research|Verstanden — erst die Recherche, dann der Einbau. Ich melde mich."
  "bug_feature|Verstanden, Sir. Ich behebe den Fehler und baue die Erweiterung ein."
  "bug_feature|Alles klar, Fix und Feature — ich mache mich an beides."
)

i=0
for row in "${lines[@]}"; do
  cat="${row%%|*}"; phrase="${row#*|}"
  mkdir -p "$out/$cat"
  fname="$(printf '%s/%s/%s_%02d.pcm' "$out" "$cat" "$cat" "$i")"
  code=$(curl -sS -w '%{http_code}' -o "$fname" -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/${voice}/stream?output_format=pcm_24000" \
    -H "xi-api-key: ${key}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$phrase" '{text:$t, model_id:"eleven_flash_v2_5", voice_settings:{stability:0.45, similarity_boost:0.85, style:0.3, use_speaker_boost:true}}')")
  if [ "$code" != "200" ]; then
    echo "ERROR: line $i ($cat) failed (HTTP $code): $(cat "$fname")"; rm -f "$fname"; exit 1
  fi
  echo "wrote $fname ($phrase)"
  i=$((i + 1))
done
echo "generate-line-clips: done ($i lines)."
