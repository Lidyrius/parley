#!/usr/bin/env bash
# Report the coding clients available to the current shell as JSON.
set -euo pipefail

has_command() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # GUI-launched apps often do not inherit the user's interactive shell PATH.
  for dir in \
    "$HOME/.local/bin" \
    "$HOME/.npm-global/bin" \
    "$HOME/.volta/bin" \
    "/opt/homebrew/bin" \
    "/usr/local/bin" \
    "/opt/local/bin"; do
    [ -x "$dir/$1" ] && return 0
  done
  return 1
}

claude=0
codex=0
has_command claude && claude=1
has_command codex && codex=1

jq -n --argjson claude "$claude" --argjson codex "$codex" \
  '{claudeCode:($claude == 1), codex:($codex == 1)}'
