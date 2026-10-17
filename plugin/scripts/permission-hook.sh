#!/usr/bin/env bash
# Parley PermissionRequest hook (permission prompts aloud).
#
# The client is about to ask the user to approve a tool call. LONG-POLL the app:
# POST /permission {"session_id","cwd","tool_name","tool_input"}. Parley says
# "<Projekt> möchte … — erlauben?", listens, and answers {"decision":"allow"|"deny"|"ask"}.
#   allow / deny -> print the PermissionRequest decision; the on-screen prompt is skipped.
#   ask, app unreachable, timeout, garbage -> no decision; the normal on-screen prompt
#   appears exactly as if this hook did not exist.
# A session Parley does not know (voice mode off) gets "ask" at once, so the hook is free
# outside voice mode. Output schema (Claude Code hooks reference, "PermissionRequest
# decision control"; Codex accepts the same shape):
#   {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
#                          "decision":{"behavior":"allow"|"deny","message":"…"}}}
set -euo pipefail

PORT="${PARLEY_PORT:-8787}"
input="$(cat)"

# Codex sends its own required `turn_id` field and wants valid JSON on stdout even when the
# hook has no decision ({} = no decision). Claude Code treats empty stdout as no decision.
is_codex=false
if printf '%s' "$input" | jq -e 'type == "object" and has("turn_id")' >/dev/null 2>&1; then
  is_codex=true
fi

no_decision() {
  [ "$is_codex" = true ] && printf '{}\n'
  exit 0
}

payload="$(printf '%s' "$input" | jq -c --arg pd "${CLAUDE_PROJECT_DIR:-}" '{
  session_id: (.session_id // ""),
  cwd:        (if $pd != "" then $pd else (.cwd // "") end),
  tool_name:  (.tool_name // ""),
  tool_input: (.tool_input // {})
}' 2>/dev/null)" || no_decision
[ -n "$payload" ] || no_decision

# Host resolution (same as stop-hook.sh): 127.0.0.1 everywhere (macOS, native Git Bash,
# WSL2 mirrored networking). Under WSL NAT mode the Windows host is reachable via the
# default gateway instead — fall back to it when loopback doesn't answer.
HOST="127.0.0.1"
if [ -n "${WSL_DISTRO_NAME:-}" ] && ! curl -sS --max-time 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  [ -n "$gw" ] && HOST="$gw"
fi

# Blocks while the question is queued + spoken + answered. The app answers within 120 s
# ("ask" when nobody replies); 125 s is the hard cap. hooks.json timeout must be >= this.
# The body goes through stdin: tool_input (Write/Edit content) can be far larger than the
# ~32 KB Windows command-line limit.
resp="$(printf '%s' "$payload" | curl -sS --connect-timeout 3 --max-time 125 \
  -X POST "http://${HOST}:${PORT}/permission" \
  -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || true)"

decision="$(printf '%s' "$resp" | jq -r \
  'if type == "object" then (.decision // "" | tostring | ascii_downcase) else "" end' \
  2>/dev/null || true)"

case "$decision" in
  allow)
    jq -nc '{hookSpecificOutput: {hookEventName: "PermissionRequest",
             decision: {behavior: "allow"}}}'
    ;;
  deny)
    jq -nc '{hookSpecificOutput: {hookEventName: "PermissionRequest",
             decision: {behavior: "deny", message: "Per Sprache abgelehnt."}}}'
    ;;
  *)
    no_decision
    ;;
esac
exit 0
