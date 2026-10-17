#!/usr/bin/env bash
# Tests plugin/scripts/permission-hook.sh (Claude Code + Codex PermissionRequest hook):
# the POST /permission request it sends, and the decision it prints for allow / deny /
# ask / garbage / dropped connection / unreachable app. A throwaway loopback responder
# records each request and answers with canned bodies.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
hook="$here/plugin/scripts/permission-hook.sh"
port=8797
dead_port=8796   # nothing listens here: "app not running"
tmp="$(mktemp -d)"
srv=""
trap 'rm -rf "$tmp"; [ -n "$srv" ] && kill "$srv" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Serve one request per argument, in order. "__CLOSE__" drops the connection without
# answering. Each request is saved as $tmp/req.N.path and $tmp/req.N.body.
start_server() {
  rm -f "$tmp"/req.* "$tmp/ready"
  : > "$tmp/responses"
  for response in "$@"; do printf '%s\n' "$response" >> "$tmp/responses"; done
  python3 - "$port" "$tmp" > "$tmp/ready" 2>&1 <<'PY' &
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
responses = [l.rstrip("\n") for l in open(out + "/responses", encoding="utf-8")]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
print("READY", flush=True)
for n, response in enumerate(responses):
    c, _ = s.accept()
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = c.recv(65536)
        if not chunk: break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    clen = 0
    for line in lines[1:]:
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":", 1)[1])
    while len(rest) < clen:
        chunk = c.recv(65536)
        if not chunk: break
        rest += chunk
    open("%s/req.%d.path" % (out, n), "wb").write(lines[0])
    open("%s/req.%d.body" % (out, n), "wb").write(rest[:clen])
    if response != "__CLOSE__":
        body = response.encode()
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                  + str(len(body)).encode() + b"\r\n\r\n" + body)
    c.close()
s.close()
PY
  srv=$!
  disown "$srv" 2>/dev/null || true
  for _ in $(seq 1 50); do
    grep -q READY "$tmp/ready" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "listener did not come up: $(cat "$tmp/ready")"
}

wait_server() { wait "$srv" 2>/dev/null || true; srv=""; }

run_hook() {  # $1 = hook stdin, $2 = port (default: the test server)
  printf '%s' "$1" | PARLEY_PORT="${2:-$port}" bash "$hook"
}

claude_in='{"session_id":"s-claude","transcript_path":"/tmp/t.jsonl","cwd":"/Users/sydney/workspace/privat/tippfrei","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}'
codex_in='{"session_id":"s-codex","turn_id":"turn-1","transcript_path":null,"cwd":"/tmp/codex-proj","model":"gpt-5","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push"}}'

# --- 1. allow -> exact allow decision; request shape -----------------------------------
start_server '{"decision":"allow"}'
out="$(run_hook "$claude_in")"
wait_server
[ "$out" = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ] \
  || fail "allow output: [$out]"
grep -q '^POST /permission HTTP/1\.[01]$' "$tmp/req.0.path" || fail "request line: $(cat "$tmp/req.0.path")"
jq -e '(keys == ["cwd","session_id","tool_input","tool_name"])
       and .session_id == "s-claude"
       and .cwd == "/Users/sydney/workspace/privat/tippfrei"
       and .tool_name == "Bash"
       and .tool_input == {"command":"rm -rf node_modules","description":"Remove node_modules directory"}' \
  "$tmp/req.0.body" >/dev/null || fail "request body: $(cat "$tmp/req.0.body")"
echo "PASS: allow -> allow decision, POST /permission with session_id/cwd/tool_name/tool_input"

# --- 2. deny -> deny decision with German message --------------------------------------
start_server '{"decision":"deny"}'
out="$(run_hook "$claude_in")"
wait_server
[ "$out" = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Per Sprache abgelehnt."}}}' ] \
  || fail "deny output: [$out]"
echo "PASS: deny -> deny decision + message"

# --- 3. ask -> no output (normal on-screen prompt) -------------------------------------
start_server '{"decision":"ask"}'
out="$(run_hook "$claude_in")"
wait_server
[ -z "$out" ] || fail "ask output should be empty: [$out]"
echo "PASS: ask -> no output"

# --- 4. garbage / unknown decision / dropped connection -> no output ------------------
for resp in 'not json at all' '{"decision":"maybe"}' '{"ok":true}' '["allow"]' '__CLOSE__'; do
  start_server "$resp"
  out="$(run_hook "$claude_in")"
  wait_server
  [ -z "$out" ] || fail "response [$resp] should give no output: [$out]"
done
echo "PASS: garbage / unknown decision / dropped connection -> no output"

# --- 5. app unreachable -> no output, exit 0, fast -------------------------------------
start=$(date +%s)
out="$(run_hook "$claude_in" "$dead_port")"
elapsed=$(( $(date +%s) - start ))
[ -z "$out" ] || fail "unreachable output should be empty: [$out]"
[ "$elapsed" -le 5 ] || fail "unreachable app took ${elapsed}s"
echo "PASS: app unreachable -> no output, exit 0 (${elapsed}s)"

# --- 6. Codex envelope: same decisions, {} when there is no decision ------------------
start_server '{"decision":"allow"}' '{"decision":"ask"}'
out="$(run_hook "$codex_in")"
[ "$out" = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ] \
  || fail "Codex allow output: [$out]"
out="$(run_hook "$codex_in")"
wait_server
[ "$out" = '{}' ] || fail "Codex ask output should be {}: [$out]"
jq -e '.session_id == "s-codex" and .tool_input == {"command":"git push"}' "$tmp/req.0.body" >/dev/null \
  || fail "Codex request body: $(cat "$tmp/req.0.body")"
out="$(run_hook "$codex_in" "$dead_port")"
[ "$out" = '{}' ] || fail "Codex unreachable output should be {}: [$out]"
echo "PASS: Codex envelope -> allow decision, {} for ask/unreachable"

# --- 7. huge tool_input (Write content) goes through intact ---------------------------
# (built via stdin: a single 300 KB argv string exceeds Linux's per-argument limit)
big_in="$(head -c 300000 /dev/zero | tr '\0' 'x' | jq -Rsc '{session_id:"s-big",cwd:"/tmp/p",hook_event_name:"PermissionRequest",tool_name:"Write",tool_input:{file_path:"/tmp/p/a.txt",content:.}}')"
start_server '{"decision":"allow"}'
out="$(run_hook "$big_in")"
wait_server
jq -e '.hookSpecificOutput.decision.behavior == "allow"' <<<"$out" >/dev/null || fail "big input output: [$out]"
[ "$(jq -r '.tool_input.content | length' "$tmp/req.0.body")" = 300000 ] || fail "big tool_input truncated"
echo "PASS: 300 KB tool_input sent intact"

# --- 8. invalid hook input -> no request, no output ------------------------------------
start_server '{"decision":"allow"}'
out="$(run_hook 'this is not json')"
[ -z "$out" ] || fail "invalid input output: [$out]"
sleep 0.2
[ ! -e "$tmp/req.0.path" ] || fail "invalid input still sent a request"
kill "$srv" 2>/dev/null || true; srv=""
echo "PASS: invalid hook input -> no request, no output"

# --- 9. hooks.json wiring (both clients read it) ----------------------------------------
jq -e '.hooks.PermissionRequest[0].hooks[0]
       | .type == "command"
         and (.command | contains("${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT}}/scripts/permission-hook.sh"))
         and (.commandWindows | contains("${PLUGIN_ROOT}/scripts/permission-hook.sh"))
         and .timeout >= 130' "$here/plugin/hooks/hooks.json" >/dev/null \
  || fail "hooks.json PermissionRequest entry"
jq -e '.hooks.Stop[0].hooks[0].type == "command"' "$here/plugin/hooks/hooks.json" >/dev/null \
  || fail "hooks.json lost the Stop hook"
echo "PASS: hooks.json wires PermissionRequest (timeout >= 130 s) next to Stop"

echo "ALL PERMISSION HOOK TESTS PASSED"
