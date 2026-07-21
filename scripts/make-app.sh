#!/usr/bin/env bash
# Build Parley.app from the SPM executable and install it to ~/Applications so it is
# double-click launchable and resolvable by `open -a Parley`. Re-run after code changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${PARLEY_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Parley.app"
BIN_NAME="Parley"

echo "==> swift build -c release"
# -suppress-warnings: keep install output clean (Swift 6 Sendable-capture noise from
# AVFoundation closures — harmless for this single-actor app). Errors still surface.
( cd "$ROOT/app" && swift build -c release -Xswiftc -suppress-warnings )

BUILD_DIR="$ROOT/app/.build/release"
[ -x "$BUILD_DIR/$BIN_NAME" ] || { echo "build produced no binary"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

# SPM resource bundle (ready clips etc.) → Contents/Resources (Bundle.main.resourceURL).
if [ -d "$BUILD_DIR/${BIN_NAME}_${BIN_NAME}.bundle" ]; then
  cp -R "$BUILD_DIR/${BIN_NAME}_${BIN_NAME}.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Parley</string>
    <key>CFBundleDisplayName</key>       <string>Parley</string>
    <key>CFBundleExecutable</key>        <string>Parley</string>
    <key>CFBundleIdentifier</key>        <string>de.developaway.parley</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parley records your spoken reply after Claude Code finishes a turn.</string>
</dict>
</plist>
PLIST

# Stable code-signing identity so macOS TCC (microphone, Accessibility) keeps its
# grants across rebuilds. Ad-hoc (`-s -`) changes the cdhash every build, which makes
# the mic grant stale → capture returns silent zeroes even while "authorized". Use a
# real signing identity; override with PARLEY_SIGN_ID, else auto-pick the first one.
SIGN_ID="${PARLEY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1{print $2}')"
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> codesign with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    || { echo "   (signed-identity codesign failed, falling back to ad-hoc)"; codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true; }
else
  echo "==> ad-hoc codesign (no stable identity found — TCC prompts may repeat)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> register with LaunchServices"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo "==> done: $APP"
echo "    launch:  open -a Parley    (or double-click in ~/Applications)"
