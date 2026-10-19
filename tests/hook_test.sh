#!/usr/bin/env bash
# Tests plugin/scripts/stop-hook.sh for Claude Code and Codex: <speak> extraction
# -> correct /turn JSON, Codex continuation output, and no-tag behavior. Spins a
# throwaway loopback listener and captures the request body.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
hook="$here/plugin/scripts/stop-hook.sh"
port=8799
bodyfile="$(mktemp)"
trap 'rm -f "$bodyfile" "${readyfile:-}"; [ -n "${srv:-}" ] && kill "$srv" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# One-shot listener: writes the POST body of a single request to $bodyfile.
readyfile="$(mktemp)"
start_listener() {
  listener_response="${1:-{\"ok\":true}}"
  : > "$bodyfile"; : > "$readyfile"
  python3 - "$port" "$bodyfile" "$listener_response" > "$readyfile" 2>&1 <<'PY' &
import socket, sys
port, out, response = int(sys.argv[1]), sys.argv[2], sys.argv[3].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
print("READY", flush=True)
c, _ = s.accept()
data = b""
while b"\r\n\r\n" not in data:
    data += c.recv(4096)
head, _, rest = data.partition(b"\r\n\r\n")
clen = 0
for line in head.split(b"\r\n"):
    if line.lower().startswith(b"content-length:"):
        clen = int(line.split(b":")[1])
while len(rest) < clen:
    rest += c.recv(4096)
open(out, "wb").write(rest)
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(response)).encode() + b"\r\n\r\n" + response)
c.close()
PY
  srv=$!
  disown "$srv" 2>/dev/null || true
  # wait for the listener to print READY (do NOT open a probe connection —
  # the listener accepts exactly one, which must be the hook's POST).
  for _ in $(seq 1 50); do
    grep -q READY "$readyfile" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "listener did not come up: $(cat "$readyfile")"
}

# --- Test 1: input WITH <speak> tag -> POST body has extracted speak text ---
start_listener
in1='{"last_assistant_message":"Here is a report.\n<speak>Tests grün, API deployed. Soll ich das Log-Level senken?</speak>","cwd":"/Users/sydney/workspace/privat/parley","session_id":"abc123"}'
printf '%s' "$in1" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true

[ -s "$bodyfile" ] || fail "no POST body received for tagged input"
got_speak="$(jq -r '.speak' < "$bodyfile")"
[ "$got_speak" = "Tests grün, API deployed. Soll ich das Log-Level senken?" ] \
  || fail "speak mismatch: [$got_speak]"
[ "$(jq -r '.event' < "$bodyfile")" = "turn" ] || fail "event != turn"
[ "$(jq -r '.session_id' < "$bodyfile")" = "abc123" ] || fail "session_id mismatch"
[ "$(jq -r '.project' < "$bodyfile")" = "parley" ] || fail "project mismatch"
echo "PASS: tagged input -> correct /turn JSON"

# --- Test 2: multiline / quotes / unicode -> valid JSON, exact text ---
start_listener
in2='{"last_assistant_message":"<speak>Zeile eins.\nEr sagte \"hallo\" — fertig? 你好 ✓</speak>","cwd":"/tmp/proj","session_id":"s2"}'
printf '%s' "$in2" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
jq -e . < "$bodyfile" >/dev/null || fail "tagged body is not valid JSON"
got2="$(jq -r '.speak' < "$bodyfile")"
[ "$got2" = $'Zeile eins.\nEr sagte "hallo" — fertig? 你好 ✓' ] || fail "multiline speak mismatch: [$got2]"
echo "PASS: multiline/quotes/unicode preserved as valid JSON"

# --- Test 3b: earlier <speak> mentions (quoted files) -> only the LAST block is spoken ---
start_listener
in3b='{"last_assistant_message":"Die Skill sagt: beende mit <speak> Tags. CONTRACT zeigt <speak>Beispiel</speak> als Muster.\n\n<speak>Ich habe alles gesichtet, Sir. Soll ich committen?</speak>","cwd":"/tmp/p","session_id":"s3b"}'
printf '%s' "$in3b" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
got3b="$(jq -r '.speak' < "$bodyfile")"
[ "$got3b" = "Ich habe alles gesichtet, Sir. Soll ich committen?" ] \
  || fail "should extract LAST speak block, got: [$got3b]"
echo "PASS: multiple <speak> mentions -> only the last block spoken"

# --- Test 3c: <speak> with NO closing tag -> take everything to end of message ---
start_listener
in3c='{"last_assistant_message":"Bericht hier.\n<speak>Ich habe fertig, Sir. Soll ich fortfahren?","cwd":"/tmp/p","session_id":"s3c"}'
printf '%s' "$in3c" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
got3c="$(jq -r '.speak' < "$bodyfile")"
[ "$got3c" = "Ich habe fertig, Sir. Soll ich fortfahren?" ] \
  || fail "missing closing tag should take to end, got: [$got3c]"
echo "PASS: missing </speak> -> text to end of message"

# --- Test 3: input WITHOUT <speak> -> hook exits 0 and POSTs nothing ---
start_listener
in3='{"last_assistant_message":"Just a normal answer, no tag.","cwd":"/tmp/x","session_id":"s3"}'
printf '%s' "$in3" | PARLEY_PORT=$port bash "$hook"
rc=$?
[ "$rc" -eq 0 ] || fail "no-tag hook exited $rc"
sleep 0.3
[ ! -s "$bodyfile" ] || fail "no-tag input still POSTed a body: $(cat "$bodyfile")"
kill "$srv" 2>/dev/null || true
echo "PASS: no-tag input -> no POST, exit 0"

# --- Test 4: Codex no-tag input -> valid empty JSON and no POST ---
start_listener
codex_no_tag='{"hook_event_name":"Stop","last_assistant_message":"A normal Codex answer.","cwd":"/tmp/x","session_id":"codex-no-tag"}'
codex_output="$(printf '%s' "$codex_no_tag" | PARLEY_PORT=$port bash "$hook")"
[ "$codex_output" = '{}' ] || fail "Codex no-tag output was not {}: [$codex_output]"
sleep 0.3
[ ! -s "$bodyfile" ] || fail "Codex no-tag input POSTed a body: $(cat "$bodyfile")"
kill "$srv" 2>/dev/null || true
echo "PASS: Codex no-tag input -> empty JSON, no POST"

# --- Test 5: Codex tagged input -> transcript becomes a continuation decision ---
start_listener '{"transcript":"Ja, bitte fortfahren."}'
codex_tagged='{"hook_event_name":"Stop","last_assistant_message":"<speak>Codex ist bereit. Soll ich fortfahren?</speak>","cwd":"/Users/sydney/workspace/privat/parley","session_id":"codex-1"}'
codex_output="$(printf '%s' "$codex_tagged" | PARLEY_PORT=$port bash "$hook")"
wait "$srv" 2>/dev/null || true
[ "$(printf '%s' "$codex_output" | jq -r '.decision')" = "block" ] || fail "Codex did not block for transcript: [$codex_output]"
[ "$(printf '%s' "$codex_output" | jq -r '.reason')" = "Ja, bitte fortfahren." ] \
  || fail "Codex transcript mismatch: [$codex_output]"
[ "$(jq -r '.session_id' < "$bodyfile")" = "codex-1" ] || fail "Codex session_id mismatch"
echo "PASS: Codex tagged input -> continuation decision"

# --- Test 6: <reply> lines directly above the final tag -> payload.replies; one in prose is not ---
start_listener
in6='{"last_assistant_message":"Format: `<reply on=\"x\">nur Prosa</reply>` ist ein Beispiel.\n\n<reply on=\"Zustimmung\">Sehr wohl, ich setze das um.</reply>\n<reply on=\"Ablehnung\" listen>Was schwebt Ihnen vor, Sir?</reply>\n<speak>Soll ich das so bauen?</speak>","cwd":"/tmp/p","session_id":"r1"}'
printf '%s' "$in6" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
[ "$(jq -c '.replies' < "$bodyfile")" = '[{"on":"Zustimmung","say":"Sehr wohl, ich setze das um.","listen":false},{"on":"Ablehnung","say":"Was schwebt Ihnen vor, Sir?","listen":true}]' ] \
  || fail "replies mismatch: $(jq -c '.replies' < "$bodyfile")"
[ "$(jq -r '.speak' < "$bodyfile")" = "Soll ich das so bauen?" ] || fail "speak with replies: $(jq -r '.speak' < "$bodyfile")"
echo "PASS: reply options parsed, prose ignored"

# --- Test 7: no reply lines -> no replies key ---
start_listener
printf '%s' "$in1" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
[ "$(jq -r 'has("replies")' < "$bodyfile")" = "false" ] || fail "unexpected replies key"
echo "PASS: no replies -> no key"

# --- Test 8: <slide/> markers leave the spoken text and keep their word index ---
start_listener
in8='{"last_assistant_message":"<speak>Der Export ist drin, Sir. <slide image=\"last\" title=\"Export\"/> So sieht er aus. <slide chart=\"bar\" labels=\"Grün,Rot\" values=\"24,2\" title=\"Tests\"/>Fast alles grün.</speak>","cwd":"/tmp/p","session_id":"s8"}'
printf '%s' "$in8" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
[ "$(jq -r '.speak' < "$bodyfile")" = "Der Export ist drin, Sir. So sieht er aus. Fast alles grün." ] || fail "slides speak: $(jq -r '.speak' < "$bodyfile")"
[ "$(jq -c '.slides' < "$bodyfile")" = '[{"word":5,"image":"last","title":"Export"},{"word":9,"chart":"bar","labels":"Grün,Rot","values":"24,2","title":"Tests"}]' ] \
  || fail "slides: $(jq -c '.slides' < "$bodyfile")"
echo "PASS: slide markers"

# --- Test 9: <speak to="Max"> asks a guest (v7) -> payload.to; a plain <speak> has none ---
start_listener
in9='{"last_assistant_message":"Zwei Varianten.\n<reply on=\"A\">Gut.</reply>\n<speak to=\"Max\">Max, welche Überschrift nehmen wir?</speak>","cwd":"/tmp/p","session_id":"s9"}'
printf '%s' "$in9" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
[ "$(jq -r '.to' < "$bodyfile")" = "Max" ] || fail "to: $(jq -c . < "$bodyfile")"
[ "$(jq -r '.speak' < "$bodyfile")" = "Max, welche Überschrift nehmen wir?" ] || fail "speak to: $(jq -r '.speak' < "$bodyfile")"
[ "$(jq -c '.replies' < "$bodyfile")" = '[{"on":"A","say":"Gut.","listen":false}]' ] || fail "replies with to: $(jq -c '.replies' < "$bodyfile")"
start_listener
printf '%s' "$in1" | PARLEY_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
[ "$(jq -r 'has("to")' < "$bodyfile")" = "false" ] || fail "unexpected to key"
echo "PASS: speak to a guest"

echo "ALL HOOK TESTS PASSED"
