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

# Already set up? Then this run is an UPDATE: refresh the app + plugin but keep the
# existing keys/voice and skip onboarding. Detected by an onboarded credential store.
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
UPDATE=0
[ -f "$CREDS" ] && [ -n "$(jq -r '.googleAPIKey // .elevenLabsAPIKey // ""' "$CREDS" 2>/dev/null)" ] && UPDATE=1
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

# 2. install the app bundle: prefer a prebuilt release (no Xcode); build only as fallback.
APP="$HOME/Applications/Parley.app"
REPO_SLUG="${PARLEY_REPO#https://github.com/}"; REPO_SLUG="${REPO_SLUG:-Lidyrius/parley}"
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

# 3. install the plugin (auto-loads every session as parley@skills-dir)
info "Installiere Claude-Code-Plugin"
mkdir -p "$HOME/.claude/skills"
ln -sfn "$SRC/plugin" "$HOME/.claude/skills/parley"

# 4. onboarding (TUI) — fresh install only; an update keeps the existing keys/voice.
if [ "$UPDATE" = 0 ]; then
  info "Starte Einrichtung"
  bash "$SRC/scripts/onboard-tui.sh"
fi

# 5. render the voice clips (fresh install, or if they're missing after an update).
GOOGLE_KEY="$(jq -r '.googleAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"
CLIPS_DIR="$HOME/Library/Application Support/Parley/clips"
if [ -n "$GOOGLE_KEY" ] && { [ "$UPDATE" = 0 ] || ! ls "$CLIPS_DIR"/ready/*.pcm >/dev/null 2>&1; }; then
  info "Rendere Sprach-Clips in deiner Sprache (Google Chirp3 HD)"
  # Writes to Application Support/Parley/clips — the app reads these at runtime, so no
  # app rebuild (and no Xcode) is needed to get clips in the chosen language + voice.
  bash "$SRC/scripts/generate-clips-google.sh" || true
fi

# 6. (re)launch the menu-bar app — on update, restart so the new binary takes effect.
[ "$UPDATE" = 1 ] && pkill -f 'MacOS/Parley' >/dev/null 2>&1 || true
sleep 1
open -a Parley >/dev/null 2>&1 || true

if [ "$UPDATE" = 1 ]; then
  printf '\n\033[1;32m✓ Parley aktualisiert.\033[0m Die App wurde neu gestartet.\n'
else
  printf '\n\033[1;32m✓ Parley installiert.\033[0m\n'
  printf 'Starte eine \033[1mneue\033[0m Claude-Code-Sitzung und tippe \033[1m/parley:voice\033[0m.\n'
  printf 'Beim ersten echten Turn: Mikrofon erlauben.\n'
fi
