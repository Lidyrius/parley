#!/usr/bin/env bash
# Apply the saved Claude Code/Codex integration choices to this checkout.
# This script is intentionally idempotent and only removes links/plugins owned by Parley.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="${PARLEY_CREDS:-$HOME/Library/Application Support/Parley/credentials.json}"

read_value() {
  [ -f "$CREDS" ] || return 0
  jq -r --arg key "$1" '.[$key] // empty' "$CREDS" 2>/dev/null || true
}

detected_claude="$(read_value detectedClaudeCode)"
detected_codex="$(read_value detectedCodex)"
enabled_claude="$(read_value claudeCodeEnabled)"
enabled_codex="$(read_value codexEnabled)"

if [ -z "$detected_claude" ] && command -v claude >/dev/null 2>&1; then detected_claude=1; fi
if [ -z "$detected_codex" ] && command -v codex >/dev/null 2>&1; then detected_codex=1; fi
[ -n "$enabled_claude" ] || enabled_claude="$detected_claude"
[ -n "$enabled_codex" ] || enabled_codex="$detected_codex"

owned_link_target() {
  local link="$1" target="$2"
  [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]
}

install_claude() {
  local link="$HOME/.claude/skills/parley"
  mkdir -p "$(dirname "$link")"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if owned_link_target "$link" "$ROOT/plugin"; then return 0; fi
    echo "Parley: not replacing existing Claude plugin path: $link" >&2
    return 1
  fi
  ln -s "$ROOT/plugin" "$link"
}

remove_claude() {
  local link="$HOME/.claude/skills/parley"
  if owned_link_target "$link" "$ROOT/plugin"; then rm "$link"; fi
}

MARKET_ROOT="${PARLEY_CODEX_MARKETPLACE:-$HOME/.parley/codex-marketplace}"
MARKET_NAME="parley-local"

ensure_codex_marketplace() {
  local link="$MARKET_ROOT/plugin"
  local marketplace_file="$MARKET_ROOT/.agents/plugins/marketplace.json"
  mkdir -p "$(dirname "$marketplace_file")"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if ! owned_link_target "$link" "$ROOT/plugin"; then
      echo "Parley: not replacing existing Codex marketplace plugin path: $link" >&2
      return 1
    fi
  else
    ln -s "$ROOT/plugin" "$link"
  fi
  jq -n \
    '{name:"parley-local", interface:{displayName:"Parley"}, plugins:[{name:"parley", source:{source:"local", path:"./plugin"}, policy:{installation:"AVAILABLE", authentication:"ON_INSTALL"}, category:"Productivity"}]}' \
    > "$marketplace_file"

  local market_root_real
  market_root_real="$(cd "$MARKET_ROOT" && pwd -P)"
  if ! codex plugin marketplace list --json 2>/dev/null |
      jq -e --arg root "$market_root_real" '.marketplaces[]? | select(.root == $root)' >/dev/null 2>&1; then
    codex plugin marketplace add "$MARKET_ROOT" >/dev/null
  fi
}

install_codex() {
  command -v codex >/dev/null 2>&1 || {
    echo "Parley: Codex is enabled but the codex command is unavailable." >&2
    return 1
  }
  codex plugin --help >/dev/null 2>&1 || {
    echo "Parley: this Codex version has no plugin command; skipping Codex integration." >&2
    return 1
  }
  ensure_codex_marketplace
  # Re-add the local plugin so a source update cannot remain stuck in Codex's cache.
  codex plugin remove "parley@${MARKET_NAME}" --json >/dev/null 2>&1 || true
  codex plugin add "parley@${MARKET_NAME}" --json >/dev/null
}

remove_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  codex plugin remove "parley@${MARKET_NAME}" --json >/dev/null 2>&1 || true
}

if [ "$enabled_claude" = "1" ] && [ "$detected_claude" = "1" ]; then
  install_claude || true
elif [ "$enabled_claude" = "0" ]; then
  remove_claude
fi

if [ "$enabled_codex" = "1" ] && [ "$detected_codex" = "1" ]; then
  install_codex || true
elif [ "$enabled_codex" = "0" ]; then
  remove_codex
fi
