#!/usr/bin/env bash
# Complete behavior suite for the Codex branch of plugin/scripts/stop-hook.sh.
# The loopback server records every request and returns deterministic /turn /wake data.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
hook="$here/plugin/scripts/stop-hook.sh"
port=8798
bodyfile="$(mktemp)"
responsefile="$(mktemp)"
readyfile="$(mktemp)"
srv=""
trap 'rm -f "$bodyfile" "$responsefile" "$readyfile"; [ -n "$srv" ] && kill "$srv" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

start_server() {
  : > "$bodyfile"; : > "$readyfile"; : > "$responsefile"
  for response in "$@"; do printf '%s\n' "$response" >> "$responsefile"; done
  python3 - "$port" "$bodyfile" "$responsefile" > "$readyfile" 2>&1 <<'PY' &
import os, socket, sys

port, body_path, response_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
responses = [line.rstrip("\n") for line in open(response_path, encoding="utf-8")]
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port)); server.listen(1)
print("READY", flush=True)

for response in responses:
    conn, _ = server.accept()
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk: break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    content_length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            content_length = int(line.split(b":", 1)[1])
    while len(rest) < content_length:
        rest += conn.recv(4096)
    with open(body_path, "ab") as body:
        if os.path.getsize(body_path): body.write(b"\n")
        body.write(rest[:content_length])
    encoded = response.encode()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
    conn.close()
server.close()
PY
  srv=$!
  disown "$srv" 2>/dev/null || true
  for _ in $(seq 1 50); do
    grep -q READY "$readyfile" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "listener did not come up: $(cat "$readyfile")"
}

wait_server() { wait "$srv" 2>/dev/null || true; srv=""; }

run_hook() {
  printf '%s' "$1" | PARLEY_PORT=$port bash "$hook"
}

json_field() { printf '%s' "$1" | jq -r "$2"; }

# 1. No tag must not call the app and must still emit valid Codex JSON.
start_server '{"transcript":"unexpected"}'
no_tag='{"hook_event_name":"Stop","last_assistant_message":"A normal answer.","cwd":"/tmp/project","session_id":"no-tag"}'
out="$(run_hook "$no_tag")"
[ "$out" = '{}' ] || fail "no-tag output: [$out]"
sleep 0.2
[ ! -s "$bodyfile" ] || fail "no-tag sent a request"
kill "$srv" 2>/dev/null || true; srv=""
echo "PASS: no tag -> {} and no request"

# 2. The last <speak> block wins, including multiline Unicode and quotes.
start_server '{"transcript":"weiter"}'
tagged='{"hook_event_name":"Stop","last_assistant_message":"Earlier <speak>ignored</speak>\n<speak>Zeile eins. Er sagte \"hallo\" — 你好 ✓?</speak>","cwd":"/tmp/project","session_id":"tagged"}'
out="$(run_hook "$tagged")"; wait_server
[ "$(json_field "$out" '.decision')" = "block" ] || fail "tagged decision: [$out]"
[ "$(json_field "$out" '.reason')" = "weiter" ] || fail "tagged reason: [$out]"
[ "$(jq -r '.speak' < "$bodyfile")" = 'Zeile eins. Er sagte "hallo" — 你好 ✓?' ] || fail "tagged speak payload"
echo "PASS: last tag and Unicode/quotes"

# 3. A missing closing </speak> is accepted; a closed speak-end is speak-only.
start_server '{"transcript":"unclosed reply"}'
unclosed='{"hook_event_name":"Stop","last_assistant_message":"<speak>Unclosed but valid enough","cwd":"/tmp/project","session_id":"unclosed"}'
out="$(run_hook "$unclosed")"; wait_server
[ "$(json_field "$out" '.reason')" = "unclosed reply" ] || fail "unclosed speak"

start_server '{"transcript":""}'
speak_end='{"hook_event_name":"Stop","last_assistant_message":"<speak-end>Good night, Sir.</speak-end>","cwd":"/tmp/project","session_id":"speak-end"}'
out="$(run_hook "$speak_end")"; wait_server
[ "$out" = '{}' ] || fail "speak-end output: [$out]"
[ "$(jq -r '.listen' < "$bodyfile")" = "false" ] || fail "speak-end did not set listen=false"
echo "PASS: unclosed speak and speak-end"

# 4. The app returning a transcript produces a Codex continuation decision.
start_server '{"transcript":"Ja, mach weiter."}'
reply='{"hook_event_name":"Stop","last_assistant_message":"<speak>Fortfahren?</speak>","cwd":"/tmp/project","session_id":"reply"}'
out="$(run_hook "$reply")"; wait_server
[ "$(json_field "$out" '.decision')" = "block" ] || fail "reply decision"
[ "$(json_field "$out" '.reason')" = "Ja, mach weiter." ] || fail "reply transcript"
echo "PASS: transcript -> continuation"

# 5. Wait and parked-session wake paths both inject their returned text.
start_server '{"wait":1,"resume":"Nach der Pause weitermachen."}'
wait_input='{"hook_event_name":"Stop","last_assistant_message":"<speak>Ich warte.</speak>","cwd":"/tmp/project","session_id":"wait"}'
out="$(run_hook "$wait_input")"; wait_server
[ "$(json_field "$out" '.reason')" = "Nach der Pause weitermachen." ] || fail "wait continuation"

start_server '{"park":true}' '{"transcript":"Aufgewacht."}'
park_input='{"hook_event_name":"Stop","last_assistant_message":"<speak-end>Die Sitzung pausiert.</speak-end>","cwd":"/tmp/project","session_id":"park"}'
out="$(run_hook "$park_input")"; wait_server
[ "$(json_field "$out" '.reason')" = "Aufgewacht." ] || fail "park/wake continuation"
jq -e 'length == 2' < <(jq -s . "$bodyfile") >/dev/null || fail "park/wake did not issue two requests"
echo "PASS: wait and park/wake"

# 6. Missing fields and app failure must fail open with valid JSON.
missing='{"hook_event_name":"Stop","cwd":"/tmp/project","session_id":"missing"}'
out="$(run_hook "$missing")"
[ "$out" = '{}' ] || fail "missing message output: [$out]"
down='{"hook_event_name":"Stop","last_assistant_message":"<speak>App down.</speak>","cwd":"/tmp/project","session_id":"down"}'
out="$(run_hook "$down")"
[ "$out" = '{}' ] || fail "app-down output: [$out]"
echo "PASS: missing input and app failure fail open"

echo "ALL CODEX HOOK TESTS PASSED"
