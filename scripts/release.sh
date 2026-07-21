#!/usr/bin/env bash
# Build, sign, zip and publish Parley.app as a GitHub release asset, so install.sh can
# fetch a prebuilt app — no Xcode on the user's machine. Signs with make-app.sh's stable
# Apple Development identity. NOT notarized: install.sh strips the quarantine xattr after
# download, which is what lets Gatekeeper run it. (Notarization is only needed if the .app
# is distributed for double-click download outside the install script — future hardening.)
#
# Usage: scripts/release.sh vX.Y.Z
set -euo pipefail
TAG="${1:?usage: release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${PARLEY_REPO_SLUG:-Lidyrius/parley}"
APP="$HOME/Applications/Parley.app"

command -v gh >/dev/null || { echo "gh CLI fehlt."; exit 1; }

bash "$ROOT/scripts/make-app.sh"
[ -d "$APP" ] || { echo "keine App unter $APP"; exit 1; }

ZIP="$(mktemp -d)/Parley.app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"   # preserves the code signature + bundle layout
echo "zipped → $ZIP ($(du -h "$ZIP" | cut -f1))"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" -R "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" -R "$REPO" \
    -t "Parley $TAG" \
    -n "Prebuilt Parley.app — no Xcode needed.

    curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
fi
echo "released $TAG → https://github.com/$REPO/releases/tag/$TAG"
