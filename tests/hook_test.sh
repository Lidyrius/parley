#!/usr/bin/env bash
# Tests plugin/scripts/stop-hook.sh: <speak> extraction -> correct /turn JSON,
# and no-tag input -> no POST at all. Spins a throwaway loopback listener,
# captures the request body, asserts on it.
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
  : > "$bodyfile"; : > "$readyfile"
  python3 - "$port" "$bodyfile" > "$readyfile" 2>&1 <<'PY' &
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
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
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
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
in1='{"last_assistant_message":"Here is a report.\n<speak>Tests grün, API deployed. Soll ich das Log-Level senken?</speak>","cwd":"/Users/sydney/workspace/privat/vloude","session_id":"abc123"}'
printf '%s' "$in1" | VLOUDE_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true

[ -s "$bodyfile" ] || fail "no POST body received for tagged input"
got_speak="$(jq -r '.speak' < "$bodyfile")"
[ "$got_speak" = "Tests grün, API deployed. Soll ich das Log-Level senken?" ] \
  || fail "speak mismatch: [$got_speak]"
[ "$(jq -r '.event' < "$bodyfile")" = "turn" ] || fail "event != turn"
[ "$(jq -r '.session_id' < "$bodyfile")" = "abc123" ] || fail "session_id mismatch"
[ "$(jq -r '.project' < "$bodyfile")" = "vloude" ] || fail "project mismatch"
echo "PASS: tagged input -> correct /turn JSON"

# --- Test 2: multiline / quotes / unicode -> valid JSON, exact text ---
start_listener
in2='{"last_assistant_message":"<speak>Zeile eins.\nEr sagte \"hallo\" — fertig? 你好 ✓</speak>","cwd":"/tmp/proj","session_id":"s2"}'
printf '%s' "$in2" | VLOUDE_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
jq -e . < "$bodyfile" >/dev/null || fail "tagged body is not valid JSON"
got2="$(jq -r '.speak' < "$bodyfile")"
[ "$got2" = $'Zeile eins.\nEr sagte "hallo" — fertig? 你好 ✓' ] || fail "multiline speak mismatch: [$got2]"
echo "PASS: multiline/quotes/unicode preserved as valid JSON"

# --- Test 3b: earlier <speak> mentions (quoted files) -> only the LAST block is spoken ---
start_listener
in3b='{"last_assistant_message":"Die Skill sagt: beende mit <speak> Tags. CONTRACT zeigt <speak>Beispiel</speak> als Muster.\n\n<speak>Ich habe alles gesichtet, Sir. Soll ich committen?</speak>","cwd":"/tmp/p","session_id":"s3b"}'
printf '%s' "$in3b" | VLOUDE_PORT=$port bash "$hook"
wait "$srv" 2>/dev/null || true
got3b="$(jq -r '.speak' < "$bodyfile")"
[ "$got3b" = "Ich habe alles gesichtet, Sir. Soll ich committen?" ] \
  || fail "should extract LAST speak block, got: [$got3b]"
echo "PASS: multiple <speak> mentions -> only the last block spoken"

# --- Test 3: input WITHOUT <speak> -> hook exits 0 and POSTs nothing ---
start_listener
in3='{"last_assistant_message":"Just a normal answer, no tag.","cwd":"/tmp/x","session_id":"s3"}'
printf '%s' "$in3" | VLOUDE_PORT=$port bash "$hook"
rc=$?
[ "$rc" -eq 0 ] || fail "no-tag hook exited $rc"
sleep 0.3
[ ! -s "$bodyfile" ] || fail "no-tag input still POSTed a body: $(cat "$bodyfile")"
kill "$srv" 2>/dev/null || true
echo "PASS: no-tag input -> no POST, exit 0"

echo "ALL HOOK TESTS PASSED"
