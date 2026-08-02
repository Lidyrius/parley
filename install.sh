#!/usr/bin/env bash
# Parley one-command installer / updater.
#   curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
# Fresh machine: downloads the app, installs the plugin, runs onboarding. Already set up:
# updates the app + plugin, keeps your keys/voice, skips onboarding, restarts the app.
set -euo pipefail

REPO_URL="${PARLEY_REPO:-https://github.com/Lidyrius/parley}"
INSTALL_DIR="${PARLEY_DIR:-$HOME/.parley/src}"

info() { printf '\033[1;35m▸ %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# 0. platform + deps
[ "$(uname)" = "Darwin" ] || die "Parley ist eine macOS-App."
# Auto-install missing tools via Homebrew when available; otherwise instruct the user.
need() { # cmd [brew-pkg]
  command -v "$1" >/dev/null && return
  if command -v brew >/dev/null; then
    info "Installiere $1 via Homebrew"
    brew install "${2:-$1}" >/dev/null 2>&1 || die "$1-Installation via brew fehlgeschlagen."
  else
    die "$1 fehlt und Homebrew ist nicht installiert. Installiere Homebrew (brew.sh) oder $1 manuell."
  fi
}
need git; need jq; need curl
# swift is NOT required: the prebuilt release is downloaded. Only the source-build
# fallback (no release available) needs it — checked there.

# Already set up? Then this run is an UPDATE: refresh the app + integrations but keep
# the existing keys/voice and client choices.
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
UPDATE=0
[ -f "$CREDS" ] && [ "$(jq -r '.onboarded // "0"' "$CREDS" 2>/dev/null || echo 0)" = "1" ] && UPDATE=1
[ "$UPDATE" = 1 ] && info "Parley ist bereits eingerichtet — führe Update aus (Einstellungen bleiben)."

# 1. locate or fetch the source
SRC=""
selfdir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$selfdir" ] && [ -f "$selfdir/scripts/make-app.sh" ] && [ -d "$selfdir/plugin" ]; then
  SRC="$selfdir"                                  # running inside a checkout
else
  info "Hole Parley nach $INSTALL_DIR"
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only >/dev/null 2>&1 || true
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" || die "git clone fehlgeschlagen ($REPO_URL)."
  fi
  SRC="$INSTALL_DIR"
fi

# Detect clients in the same shell that will install their integrations. Persist only
# non-secret context so the visual onboarding can show accurate choices after launch.
detected="$(bash "$SRC/scripts/detect-integrations.sh")"
detected_claude="$(printf '%s' "$detected" | jq -r '.claudeCode // false')"
detected_codex="$(printf '%s' "$detected" | jq -r '.codex // false')"
mkdir -p "$(dirname "$CREDS")"
context_tmp="$(mktemp)"
if [ -f "$CREDS" ]; then
  jq '.' "$CREDS" > "$context_tmp" 2>/dev/null || printf '{}\n' > "$context_tmp"
else
  printf '{}\n' > "$context_tmp"
fi
jq --arg claude "$([ "$detected_claude" = true ] && echo 1 || echo 0)" \
   --arg codex "$([ "$detected_codex" = true ] && echo 1 || echo 0)" \
   --arg source "$SRC" \
   '.detectedClaudeCode=$claude | .detectedCodex=$codex | .sourceDir=$source' \
   "$context_tmp" > "$context_tmp.next"
mv "$context_tmp.next" "$CREDS"
chmod 600 "$CREDS"
rm -f "$context_tmp"

# 2. install the app bundle: prefer a prebuilt release (no Xcode); build only as fallback.
APP="$HOME/Applications/Parley.app"
REPO_SLUG="${PARLEY_REPO:-}"; REPO_SLUG="${REPO_SLUG#https://github.com/}"; REPO_SLUG="${REPO_SLUG:-Lidyrius/parley}"
REL_URL="https://github.com/${REPO_SLUG}/releases/latest/download/Parley.app.zip"
REL_ZIP="$(mktemp -d)/Parley.app.zip"
if curl -fsSL "$REL_URL" -o "$REL_ZIP" 2>/dev/null && [ -s "$REL_ZIP" ]; then
  info "Installiere fertige Parley.app (kein Build nötig)"
  rm -rf "$APP"; mkdir -p "$HOME/Applications"
  ditto -x -k "$REL_ZIP" "$HOME/Applications"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # let Gatekeeper run the downloaded app
  rm -f "$REL_ZIP"
else
  command -v swift >/dev/null || die "Kein Release verfügbar und Swift/Xcode fehlt zum Bauen."
  info "Baue Parley.app aus Quellcode"
  bash "$SRC/scripts/make-app.sh"
fi

# 3. install detected/enabled client integrations. The sync is idempotent and only
#    touches Parley's own Claude symlink and Codex marketplace/plugin.
info "Prüfe Claude-Code- und Codex-Integration"
bash "$SRC/scripts/sync-integrations.sh" || true

# 4. (re)launch the app. On first install it opens the visual onboarding window itself
#    (keys, language, voice, notifications, mic) — no CLI onboarding. Voice clips render
#    lazily in-app afterwards. On update, restart so the new binary takes effect.
[ "$UPDATE" = 1 ] && pkill -f 'MacOS/Parley' >/dev/null 2>&1 || true
sleep 1
open -a Parley >/dev/null 2>&1 || true

if [ "$UPDATE" = 1 ]; then
  printf '\n\033[1;32m✓ Parley aktualisiert.\033[0m Die App wurde neu gestartet.\n'
else
  printf '\n\033[1;32m✓ Parley installiert.\033[0m\n'
  printf 'Das Einrichtungsfenster öffnet sich automatisch. Danach eine \033[1mneue\033[0m Sitzung starten.\n'
  [ "$detected_claude" = true ] && printf 'Claude Code: \033[1m/parley:voice\033[0m\n'
  [ "$detected_codex" = true ] && printf 'Codex: \033[1m$parley-voice\033[0m\n'
  if [ "$detected_claude" != true ] && [ "$detected_codex" != true ]; then
    printf 'Kein Client erkannt — die offiziellen Installationslinks stehen im Setup.\n'
  fi
fi
