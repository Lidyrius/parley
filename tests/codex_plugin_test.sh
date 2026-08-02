#!/usr/bin/env bash
# Validate the Codex package and exercise the installer-side detection/synchronizer
# without touching the real home directory or Codex installation.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
real_codex="$(command -v codex || true)"
validator="${CODEX_PLUGIN_VALIDATOR:-}"
if [ -z "$validator" ] && [ -f "${HOME:-}/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" ]; then
  validator="${HOME}/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py"
fi

if [ -n "$validator" ]; then
  python3 "$validator" "$here/plugin" >/dev/null || fail "Codex plugin manifest validation"
else
  jq -e '.name == "parley" and .version and (.skills == "./skills/")' \
    "$here/plugin/.codex-plugin/plugin.json" >/dev/null || fail "Codex plugin manifest validation"
fi
jq -e '.name == "parley" and (.skills | type == "string")' \
  "$here/plugin/.codex-plugin/plugin.json" >/dev/null || fail "manifest metadata"
[ -f "$here/plugin/skills/parley-voice/SKILL.md" ] || fail "Codex voice skill missing"
jq -e '.hooks.Stop[0].hooks[0].type == "command"' "$here/plugin/hooks/hooks.json" >/dev/null \
  || fail "shared Stop hook missing"
echo "PASS: Codex plugin manifest, skill, and hook package"

mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CODEX_LOG:?}"
if [ "$1 ${2:-}" = "plugin --help" ]; then exit 0; fi
if [ "$1 ${2:-} ${3:-}" = "plugin marketplace list" ]; then
  printf '%s\n' '{"marketplaces":[]}'
fi
exit 0
SH
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
export FAKE_CODEX_LOG="$tmp/codex.log"
export PATH="$tmp/bin:$PATH"

detected="$(HOME="$tmp/home" bash "$here/scripts/detect-integrations.sh")"
[ "$(printf '%s' "$detected" | jq -r '.claudeCode')" = true ] || fail "Claude detection"
[ "$(printf '%s' "$detected" | jq -r '.codex')" = true ] || fail "Codex detection"
echo "PASS: client detection"

mkdir -p "$tmp/home/.local/bin"
cp "$tmp/bin/claude" "$tmp/home/.local/bin/claude"
cp "$tmp/bin/codex" "$tmp/home/.local/bin/codex"
path_only_detection="$(HOME="$tmp/home" PATH="/usr/bin:/bin" bash "$here/scripts/detect-integrations.sh")"
[ "$(printf '%s' "$path_only_detection" | jq -r '.claudeCode')" = true ] || fail "GUI-path Claude detection"
[ "$(printf '%s' "$path_only_detection" | jq -r '.codex')" = true ] || fail "GUI-path Codex detection"
echo "PASS: GUI-path client detection"

creds="$tmp/credentials.json"
printf '%s\n' '{"detectedClaudeCode":"0","detectedCodex":"1","claudeCodeEnabled":"0","codexEnabled":"1"}' > "$creds"
HOME="$tmp/home" PARLEY_CREDS="$creds" bash "$here/scripts/sync-integrations.sh"
market="$tmp/home/.parley/codex-marketplace"
[ -L "$market/plugin" ] || fail "Codex plugin link"
[ "$(readlink "$market/plugin")" = "$here/plugin" ] || fail "Codex plugin link target"
jq -e '.name == "parley-local" and .plugins[0].source.path == "./plugin"' \
  "$market/.agents/plugins/marketplace.json" >/dev/null || fail "local marketplace shape"
grep -Fq 'plugin add parley@parley-local' "$FAKE_CODEX_LOG" || fail "Codex add command"
echo "PASS: Codex marketplace synchronization"

printf '%s\n' '{"detectedClaudeCode":"0","detectedCodex":"1","claudeCodeEnabled":"0","codexEnabled":"0"}' > "$creds"
HOME="$tmp/home" PARLEY_CREDS="$creds" bash "$here/scripts/sync-integrations.sh"
grep -Fq 'plugin remove parley@parley-local' "$FAKE_CODEX_LOG" || fail "Codex remove command"
echo "PASS: disabled Codex integration"

mkdir -p "$tmp/home/.claude/skills"
ln -s "$tmp/other-plugin" "$tmp/home/.claude/skills/parley"
printf '%s\n' '{"detectedClaudeCode":"0","detectedCodex":"0","claudeCodeEnabled":"0","codexEnabled":"0"}' > "$creds"
HOME="$tmp/home" PARLEY_CREDS="$creds" bash "$here/scripts/sync-integrations.sh"
[ -L "$tmp/home/.claude/skills/parley" ] || fail "foreign Claude link was removed"
[ "$(readlink "$tmp/home/.claude/skills/parley")" = "$tmp/other-plugin" ] || fail "foreign Claude link changed"
echo "PASS: foreign Claude link is preserved"

if [ -n "$real_codex" ]; then
  real_home="$tmp/real-home"
  real_codex_home="$real_home/.codex"
  real_market="$real_home/.parley/codex-marketplace"
  real_creds="$real_home/credentials.json"
  mkdir -p "$real_codex_home"
  printf '%s\n' '{"detectedClaudeCode":"0","detectedCodex":"1","claudeCodeEnabled":"0","codexEnabled":"1"}' > "$real_creds"
  HOME="$real_home" CODEX_HOME="$real_codex_home" PARLEY_CREDS="$real_creds" \
    PARLEY_CODEX_MARKETPLACE="$real_market" PATH="$(dirname "$real_codex"):/usr/bin:/bin" \
    bash "$here/scripts/sync-integrations.sh"
  HOME="$real_home" CODEX_HOME="$real_codex_home" "$real_codex" plugin list --json |
    jq -e '.installed[]? | select(.pluginId == "parley@parley-local")' >/dev/null \
    || fail "real Codex did not install the local plugin"
  echo "PASS: real Codex CLI installs the local plugin"
fi

echo "ALL CODEX PLUGIN TESTS PASSED"
