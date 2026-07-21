#!/usr/bin/env bash
# Regenerate ALL cached clips (greeting + per-intent ack lines) with Google Cloud TTS
# (Chirp3 HD, voice from env or Alnilam), so cached audio matches the live Google voice.
# Reads the key from GOOGLE_TTS_API_KEY or the app's credential store. bash 3.2 safe.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
KEY="${GOOGLE_TTS_API_KEY:-$(jq -r '.googleAPIKey // ""' "$CREDS" 2>/dev/null || echo "")}"
VOICE="${GOOGLE_TTS_VOICE:-$(jq -r '.googleVoice // "de-DE-Chirp3-HD-Alnilam"' "$CREDS" 2>/dev/null || echo "de-DE-Chirp3-HD-Alnilam")}"
[ -n "$VOICE" ] || VOICE="de-DE-Chirp3-HD-Alnilam"
LANG="$(printf '%s' "$VOICE" | cut -d- -f1-2)"

if [ -z "$KEY" ]; then echo "generate-clips-google: no Google TTS key — skipping."; exit 0; fi

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
    echo "  retry $try ($code) for: $text"; sleep 5
  done
  if [ "$code" != "200" ]; then echo "ERROR ($code) for: $text"; jq -r '.error.message // .' "$tmp.json" | head -1; rm -f "$tmp" "$tmp.json"; exit 1; fi
  jq -r '.audioContent' "$tmp.json" | base64 -D > "$tmp"
  tail -c +45 "$tmp" > "$out"          # strip 44-byte WAV header → raw pcm_24000
  rm -f "$tmp" "$tmp.json"
  echo "wrote $out"
}

# --- greeting clips ---
ready_out="$here/app/Sources/Parley/Resources/ready"
mkdir -p "$ready_out"; rm -f "$ready_out"/*.pcm
ready=(
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
i=0; for p in "${ready[@]}"; do synth "$p" "$(printf '%s/ready_%02d.pcm' "$ready_out" "$i")"; i=$((i+1)); done

# --- per-intent ack lines ---
lines_out="$here/app/Sources/Parley/Resources/lines"
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
# clear old
for c in feature bug stop continue other question research feature_research bug_feature; do
  rm -f "$lines_out/$c"/*.pcm 2>/dev/null || true; mkdir -p "$lines_out/$c"
done
i=0; for row in "${lines[@]}"; do
  cat="${row%%|*}"; phrase="${row#*|}"
  synth "$phrase" "$(printf '%s/%s/%s_%02d.pcm' "$lines_out" "$cat" "$cat" "$i")"; i=$((i+1))
done
echo "generate-clips-google: done."
