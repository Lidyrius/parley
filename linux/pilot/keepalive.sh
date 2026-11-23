#!/bin/bash
# Keeps the server browsers' logins warm: every 2–4 h (random), the read-only access check
# opens each profile's services in a new tab and closes it again — no clicks, no input.
# Profiles: ~/keepalive/profiles, one per line "<name> <cdp url> <services.json>" (on the
# server only — the lists name customer systems); without it the agency browser's defaults.
# Result: ~/keepalive/status.txt (last run), ~/keepalive/log (history), ~/keepalive/ALERT while
# a login is gone (removed again once all are back), one line per problem: "[profile] service …" —
# Parley's `alertsFile` (docs/IPHONE.md, v10). The Zentrale reads status.txt in its rounds.
#   keepalive.sh run      loop forever (start it in tmux session `keepalive`)
#   keepalive.sh once     one check now
#   keepalive.sh status   print the last result
set -u
D="$HOME/keepalive"; mkdir -p "$D"
CDP="${PARLEY_BROWSER_CDP:-http://10.252.0.10:9223}"
check() {
  local out="" rc=0 name cdp svc o
  local profiles="$D/profiles"; [ -s "$profiles" ] || profiles=<(echo "dev $CDP")
  while read -r name cdp svc; do
    [ -n "$name" ] || continue
    o="$(cd "$HOME/pilot" && timeout 300 node access-check.js "$cdp" ${svc:+"$svc"} 2>&1)" || rc=$?
    out+="[$name]"$'\n'"$o"$'\n'
  done < "$profiles"
  out="${out%$'\n'}"
  { echo "checked $(date '+%Y-%m-%d %H:%M %Z')"; echo "$out"; } > "$D/status.txt"
  sed "s/^/$(date '+%F %T') /" <<<"$out" >> "$D/log"
  if [ $rc -ne 0 ] || grep -qE 'LOGIN NÖTIG|FEHLER' <<<"$out"; then
    # "[saf] Teams LOGIN NÖTIG …": the profile in brackets is the desktop Parley opens for it (v10)
    # — stable text, so a login that stays gone is pushed once (details: status.txt)
    awk '/^\[.*\]$/ { p = $0; next } / LOGIN NÖTIG /  { print p " " $1 ": bitte neu anmelden"; next }
         / FEHLER / { print p " " $1 ": Fehler beim Prüfen" }' <<<"$out" > "$D/ALERT"
    [ -s "$D/ALERT" ] || echo "check failed (rc $rc)" > "$D/ALERT"
  else rm -f "$D/ALERT"; fi
}
case "${1:-}" in
  # while a login is gone: every 15 min, so the Hinweis goes once Sir has logged in again
  run) while true; do check; if [ -f "$D/ALERT" ]; then sleep 900; else sleep $(( 7200 + RANDOM % 7200 )); fi; done ;;
  once) check; cat "$D/status.txt"; [ -f "$D/ALERT" ] && { echo "ALERT"; exit 1; } || true ;;
  status) cat "$D/status.txt" 2>/dev/null || echo "noch kein Lauf"; [ -f "$D/ALERT" ] && echo "ALERT: $(tr '\n' ';' < "$D/ALERT")" || echo "ok" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
