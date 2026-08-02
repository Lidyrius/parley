#!/usr/bin/env bash
# Exercise the Codex greeting script's health/registration distinction.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
server=""
trap 'if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

start_server() {
  local port="$1" ready_code="$2" ready_file="$tmp/ready-$port"
  python3 - "$port" "$ready_code" "$ready_file" >"$tmp/server-$port.log" 2>&1 <<'PY' &
import http.server
import pathlib
import sys

port = int(sys.argv[1])
ready_code = int(sys.argv[2])
ready_file = pathlib.Path(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", "11")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        if self.path != "/ready":
            self.send_error(404)
            return
        body = b'{"ok":true}' if ready_code == 200 else b'{"ok":false}'
        self.send_response(ready_code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
ready_file.touch()
server.serve_forever()
PY
  server=$!
  for _ in $(seq 1 50); do
    [ -f "$ready_file" ] && return 0
    sleep 0.1
  done
  fail "test server did not start: $(cat "$tmp/server-$port.log")"
}

port=8897
start_server "$port" 200
armed="$(PARLEY_PORT="$port" bash "$here/plugin/scripts/greet.sh")"
printf '%s\n' "$armed" | grep -Fq 'parley: armed' || fail "healthy app was not armed"
echo "PASS: healthy app is armed"
kill "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
server=""

port=8898
start_server "$port" 503
registration_failed="$(PARLEY_PORT="$port" bash "$here/plugin/scripts/greet.sh")"
printf '%s\n' "$registration_failed" | grep -Fq 'app is running' || fail "registration failure was reported as unreachable"
printf '%s\n' "$registration_failed" | grep -Fq '/ready' || fail "registration failure did not name /ready"
if printf '%s\n' "$registration_failed" | grep -Fq 'app not reachable'; then
  fail "registration failure used the old misleading message"
fi
echo "PASS: reachable app with failed /ready is reported accurately"

echo "ALL GREET TESTS PASSED"
