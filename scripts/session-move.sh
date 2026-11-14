#!/usr/bin/env bash
# Moves a Claude Code session between this Mac and the server host (the Linux pilot), state and all:
#   session-move.sh check     <id>                 what the session needs there (MCPs, browser, Docker, secrets, ports)
#   session-move.sh to-server <id> [--without-secrets] [--dry-run]
#   session-move.sh copy-to-server <id> [...]     the same copy, but the Mac session keeps running and
#                                                  nothing starts on the server (a standby copy)
#   session-move.sh to-mac    <id> [--dry-run]
#   options: --exclude-from FILE  more rsync patterns to leave out (besides .parley-move-exclude)
#   session-move.sh status    <id>                 where it runs now
# to-server: copies the project folder (git state, uncommitted and untracked files; same path
# /Users/sydney/…), ends the session on the Mac through Parley's /close, copies its transcript,
# subagent files and the project's memory, and resumes it on the server through the server's
# /dispatch (voice mode and Remote Control as every Parley start). to-mac is the way back.
# Secrets (.env*, keys, certificates, password/secret files) travel with it — only over SSH (the
# tailnet), forced to 0600 on the server, their names and never their values in the output;
# --without-secrets leaves them behind. Never copied: dependencies (node_modules, .venv … —
# rebuilt there) and whatever the project lists in
# `.parley-move-exclude` (rsync patterns, e.g. customer data that must stay on the Mac).
# Nothing is deleted on either side. Uses the server's ssh alias PARLEY_SERVER (developaway-big-boi).
set -euo pipefail
exec </dev/null   # ssh and rsync would otherwise eat a caller's stdin (a `while read` loop over ids)
SERVER="${PARLEY_SERVER:-developaway-big-boi}"
ROOT=/opt/parley-pilot/home            # the pilot's /Users/sydney on the host
CT=parley-pilot
verb="${1:-}"; id="${2:-}"; shift 2 2>/dev/null || true
secrets=1; dry=0; xfile=""
while [ $# -gt 0 ]; do case "$1" in --without-secrets) secrets=0 ;; --with-secrets) secrets=1 ;; --dry-run) dry=1 ;; --exclude-from) xfile="$2"; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; shift; done
[[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { sed -n '2,15p' "$0"; exit 2; }

on_server() { ssh "$SERVER" "docker exec -u sydney $CT bash -lc $(printf %q "$1")"; }
server_post() { on_server "curl -sS --max-time 15 -X POST http://127.0.0.1:8787$1 -H 'Content-Type: application/json' -d $(printf %q "$2")"; }
mac_post() { curl -sS --max-time 15 -X POST "http://127.0.0.1:8787$1" -H 'Content-Type: application/json' -d "$2"; }

jsonl="$(ls "$HOME"/.claude/projects/*/"$id".jsonl 2>/dev/null | head -1)"
[ -n "$jsonl" ] || { echo "no transcript for $id on this Mac" >&2; exit 1; }
slugdir="$(dirname "$jsonl")"; slug="$(basename "$slugdir")"
cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$jsonl" | cut -d'"' -f4)"
[[ "$cwd" == "$HOME"/* && -d "$cwd" ]] || { echo "session folder $cwd is not under $HOME" >&2; exit 1; }
rel="${cwd#"$HOME"/}"
marker="$slugdir/.parley-moved-$id"

# Secret files by name — not source files that merely mention passwords (recover-password-form.tsx,
# WordPress' class-wp-application-passwords.php …): a "password" or "secret" name only as a dotfile
# or data file. Examples and samples of .env stay (they hold no values).
SECRET_PATTERNS=('.env' '.env.*' '*.pem' '*.key' '*.p8' '*.p12' '*.pfx' '.npmrc' 'credentials*.json'
  '.*password*' '*password*.txt' '*secret*.json' '*secret*.txt' '*.secret' 'id_rsa*' 'id_ed25519*' '*gauth*.json' 'service-account*.json')
SECRET_KEEP=('.env.example' '.env.sample' '.env.template')
DEP_PATTERNS=('.playwright-mcp/' 'node_modules/' '.venv/' 'venv/' '__pycache__/' '.next/' '.turbo/' '.DS_Store')
excludes() {
  local p; for p in "${DEP_PATTERNS[@]}"; do printf -- '--exclude=%s\n' "$p"; done
  [ "$secrets" = 1 ] || for p in "${SECRET_KEEP[@]}"; do printf -- '--include=%s\n' "$p"; done
  [ "$secrets" = 1 ] || for p in "${SECRET_PATTERNS[@]}"; do printf -- '--exclude=%s\n' "$p"; done
  [ -f "$cwd/.parley-move-exclude" ] && printf -- '--exclude-from=%s\n' "$cwd/.parley-move-exclude"
  [ -n "$xfile" ] && printf -- '--exclude-from=%s\n' "$xfile"
  return 0
}

running_mac() { grep -l "\"sessionId\":\"$id\"" "$HOME"/.claude/sessions/*.json 2>/dev/null | head -1 || true; }
running_server() { on_server "grep -l '\"sessionId\":\"$id\"' ~/.claude/sessions/*.json 2>/dev/null | head -1" || true; }

check() {
  echo "Session $id — $cwd"
  echo "Ordner gesamt (ohne node_modules/.venv): $(du -sh -I node_modules -I .venv -I venv "$cwd" 2>/dev/null | cut -f1)"
  [ -d "$cwd/.git" ] && echo "Git: $(git -C "$cwd" remote get-url origin 2>/dev/null || echo 'kein origin'), $(git -C "$cwd" status --porcelain | wc -l | tr -d ' ') geänderte/ungetrackte Dateien (werden mitkopiert)"
  echo "MCP-Server (auf dem Server neu anlegen/anmelden):"
  [ -f "$cwd/.mcp.json" ] && jq -r '.mcpServers | to_entries[] | "  - \(.key) (.mcp.json, \(.value.type // "stdio")) — kommt mit dem Ordner, Anmeldung neu"' "$cwd/.mcp.json"
  jq -r --arg c "$cwd" '.projects[$c].mcpServers // {} | keys[] | "  - \(.) (lokal in ~/.claude.json) — von Hand anlegen: claude mcp add …"' "$HOME/.claude.json" 2>/dev/null
  echo "Browser, die die Session benutzt hat (Werkzeugaufrufe im Verlauf):"
  grep -oE '"name":"mcp__(claude-in-chrome|playwright|browser-[a-z]+)__' "$jsonl" | sort | uniq -c | sed -E 's/"name":"mcp__([^_]+(-[a-z]+)?)__/\1/; s/^/  /' || echo "  keine"
  echo "Docker:"
  local f; while IFS= read -r f; do
    echo "  - ${f#"$cwd"/}: Images $(grep -E '^\s*image:' "$f" | awk '{print $2}' | tr '\n' ' ')"
    grep -E '^\s*-\s*/' "$f" | sed -E 's/^\s*-\s*/      Pfad außerhalb des Projekts: /' || true
    grep -oE '"?[0-9.]*:?[0-9]+:[0-9]+"?' "$f" | sed 's/^/      Port /' || true
  done < <(find "$cwd" -maxdepth 3 \( -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' \) -not -path '*/node_modules/*')
  [ "$secrets" = 1 ] && echo "Secrets (kommen mit, auf dem Server 0600 — nur Namen):" || echo "Secrets (bleiben am Mac, --without-secrets):"
  local fa=(); for f in "${SECRET_PATTERNS[@]}"; do fa+=(-name "$f" -o); done
  (cd "$cwd" && find . -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "./.git/*" \( "${fa[@]}" -false \) -print | sed "s/^/  - /")
  [ -f "$cwd/.parley-move-exclude" ] && { echo "Bleibt auf dem Mac (.parley-move-exclude):"; sed 's/^/  - /' "$cwd/.parley-move-exclude"; }
  return 0
}

case "$verb" in
  check) check ;;
  status)
    m="$(running_mac)"; s="$(running_server)"
    echo "Mac: $([ -n "$m" ] && echo läuft || echo "läuft nicht")   Server: $([ -n "$s" ] && echo läuft || echo "läuft nicht")"
    [ -f "$marker" ] && echo "Zuletzt verschoben: $(cat "$marker")"; true ;;
  copy-to-server|to-server)
    copy=0; [ "$verb" = copy-to-server ] && copy=1
    check; echo
    opts=(-a); [ "$dry" = 1 ] && opts+=(-n)
    ex=(); while IFS= read -r l; do ex+=("$l"); done < <(excludes)
    echo "1/4 Projektordner → Server (Vorlauf, die Session läuft noch)"
    ssh "$SERVER" "mkdir -p $(printf %q "$ROOT/$rel")"
    rsync "${opts[@]}" "${ex[@]}" "$cwd/" "$SERVER:$ROOT/$rel/"
    [ "$dry" = 1 ] && { echo "(dry run — nichts beendet, nichts gestartet)"; exit 0; }
    echo "2/4 Session am Mac beenden"
    if [ "$copy" = 1 ]; then echo "    (nur kopieren — sie läuft am Mac weiter)"
    elif [ -n "$(running_mac)" ]; then
      mac_post /close "{\"id\":\"$id\"}"; echo
      for _ in $(seq 1 30); do [ -z "$(running_mac)" ] && break; sleep 1; done
      [ -z "$(running_mac)" ] || { echo "läuft am Mac noch — abgebrochen, nichts gestartet" >&2; exit 1; }
    fi
    echo "3/4 Letzter Stand + Verlauf → Server"
    rsync "${opts[@]}" "${ex[@]}" "$cwd/" "$SERVER:$ROOT/$rel/"
    ssh "$SERVER" "mkdir -p $(printf %q "$ROOT/.claude/projects/$slug")"
    rsync -a "$jsonl" $( [ -d "$slugdir/$id" ] && printf %q "$slugdir/$id" ) $( [ -d "$slugdir/memory" ] && printf %q "$slugdir/memory" ) "$SERVER:$ROOT/.claude/projects/$slug/"
    ssh "$SERVER" "chown -R 1500:1500 $(printf %q "$ROOT/$rel") $(printf %q "$ROOT/.claude/projects/$slug")"
    [ "$secrets" = 1 ] && ssh "$SERVER" "cd $(printf %q "$ROOT/$rel") && find . -not -path './.git/*' \( $(printf -- "-name '%s' -o " "${SECRET_PATTERNS[@]}") -false \) -type f -exec chmod 600 {} +"
    [ "$copy" = 1 ] && { echo "4/4 bereitgelegt — fortsetzen: POST /dispatch {resume:\"$id\"} auf dem Server"; exit 0; }
    echo "4/4 Auf dem Server fortsetzen"
    server_post /dispatch "$(jq -nc --arg r "$id" --arg c "$cwd" '{resume:$r, cwd:$c, start:true, instruction:"Diese Session wurde vom Mac auf den Server verschoben und läuft jetzt dort weiter. Prüfe kurz Ordner, Git-Stand und Werkzeuge und melde dich."}')"; echo
    echo "server $(date '+%F %T')" > "$marker" ;;
  to-mac)
    opts=(-a); [ "$dry" = 1 ] && opts+=(-n)
    ex=(); while IFS= read -r l; do ex+=("$l"); done < <(excludes)
    [ "$dry" = 1 ] && { rsync "${opts[@]}" "${ex[@]}" "$SERVER:$ROOT/$rel/" "$cwd/"; exit 0; }
    echo "1/3 Session auf dem Server beenden"
    if [ -n "$(running_server)" ]; then
      server_post /close "{\"id\":\"$id\"}"; echo
      for _ in $(seq 1 30); do [ -z "$(running_server)" ] && break; sleep 1; done
      [ -z "$(running_server)" ] || { echo "läuft auf dem Server noch — abgebrochen" >&2; exit 1; }
    fi
    echo "2/3 Projektordner + Verlauf → Mac (nichts wird gelöscht)"
    rsync "${opts[@]}" "${ex[@]}" "$SERVER:$ROOT/$rel/" "$cwd/"
    rsync -a "$SERVER:$ROOT/.claude/projects/$slug/$id.jsonl" "$slugdir/"
    ssh "$SERVER" "test -d $(printf %q "$ROOT/.claude/projects/$slug/$id")" && rsync -a "$SERVER:$ROOT/.claude/projects/$slug/$id" "$slugdir/"
    ssh "$SERVER" "test -d $(printf %q "$ROOT/.claude/projects/$slug/memory")" && rsync -a "$SERVER:$ROOT/.claude/projects/$slug/memory" "$slugdir/"
    echo "3/3 Am Mac fortsetzen"
    mac_post /dispatch "$(jq -nc --arg r "$id" --arg c "$cwd" '{resume:$r, cwd:$c, start:true, instruction:"Diese Session wurde vom Server zurück auf den Mac geholt und läuft jetzt hier weiter."}')"; echo
    echo "mac $(date '+%F %T')" > "$marker" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
