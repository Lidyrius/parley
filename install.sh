#!/usr/bin/env bash
# Parley one-command installer.
#   curl -fsSL https://raw.githubusercontent.com/Lidyrius/parley/main/install.sh | bash
# Builds the macOS app, installs the Claude Code plugin, and runs onboarding — so a
# fresh Claude Code session can use /parley:voice right away.
set -euo pipefail

REPO_URL="${PARLEY_REPO:-https://github.com/Lidyrius/parley}"
INSTALL_DIR="${PARLEY_DIR:-$HOME/.parley/src}"

info() { printf '\033[1;35m▸ %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# 0. platform + deps
[ "$(uname)" = "Darwin" ] || die "Parley ist eine macOS-App."
command -v git  >/dev/null || die "git fehlt."
command -v jq   >/dev/null || die "jq fehlt (brew install jq)."
command -v curl >/dev/null || die "curl fehlt."
# swift is NOT required: the prebuilt release is downloaded. Only the source-build
# fallback (no release available) needs it — checked there.

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
if curl -fsSL "$REL_URL" -o "$INSTALL_DIR/Parley.app.zip" 2>/dev/null \
   && [ -s "$INSTALL_DIR/Parley.app.zip" ]; then
  info "Installiere fertige Parley.app (kein Build nötig)"
  rm -rf "$APP"; mkdir -p "$HOME/Applications"
  ditto -x -k "$INSTALL_DIR/Parley.app.zip" "$HOME/Applications"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # let Gatekeeper run the downloaded app
  rm -f "$INSTALL_DIR/Parley.app.zip"
else
  command -v swift >/dev/null || die "Kein Release verfügbar und Swift/Xcode fehlt zum Bauen."
  info "Baue Parley.app aus Quellcode"
  bash "$SRC/scripts/make-app.sh"
fi

# 3. install the plugin (auto-loads every session as parley@skills-dir)
info "Installiere Claude-Code-Plugin"
mkdir -p "$HOME/.claude/skills"
ln -sfn "$SRC/plugin" "$HOME/.claude/skills/parley"

# 4. onboarding (TUI) — collects the API keys, language, voice, microphone
info "Starte Einrichtung"
bash "$SRC/scripts/onboard-tui.sh"

# 5. render the Jarvis greeting clips using the key just entered, then rebuild so they
#    ship in the bundle (best-effort — a silent greeting is fine if this is skipped).
CREDS="$HOME/Library/Application Support/Parley/credentials.json"
GOOGLE_KEY="$(jq -r '.googleAPIKey // ""' "$CREDS" 2>/dev/null || echo "")"
if [ -n "$GOOGLE_KEY" ]; then
  info "Rendere Sprach-Clips in deiner Sprache (Google Chirp3 HD)"
  # Writes to Application Support/Parley/clips — the app reads these at runtime, so no
  # app rebuild (and no Xcode) is needed to get clips in the chosen language + voice.
  bash "$SRC/scripts/generate-clips-google.sh" || true
fi

# 6. launch the menu-bar app
open -a Parley >/dev/null 2>&1 || true

printf '\n\033[1;32m✓ Parley installiert.\033[0m\n'
printf 'Starte eine \033[1mneue\033[0m Claude-Code-Sitzung und tippe \033[1m/parley:voice\033[0m.\n'
printf 'Beim ersten echten Turn: Mikrofon & Bedienungshilfen erlauben.\n'
