#!/usr/bin/env bash
# Build a release binary and assemble a double-clickable trifola.app in ./dist/.
set -euo pipefail

# Resolve the project root (this script lives in <root>/Scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# The SwiftPM executable product (see Package.swift).
BIN_NAME="Trifola"
# The assembled bundle (lowercase, matches the CLI/brew cask name).
BUNDLE="dist/trifola.app"

echo "==> Building release…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "$BIN_PATH" "${BUNDLE}/Contents/MacOS/${BIN_NAME}"
chmod +x "${BUNDLE}/Contents/MacOS/${BIN_NAME}"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Trifola</string>
    <key>CFBundleDisplayName</key>
    <string>Trifola</string>
    <key>CFBundleIdentifier</key>
    <string>com.ss251.trifola</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Trifola uses Automation to focus the exact Terminal or iTerm session you choose.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# PkgInfo is optional but conventional for a well-formed bundle.
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Ad-hoc code signature — FREE, no Apple Developer certificate required. Gives the
# bundle a stable signature so a locally-built app runs cleanly (notably on Apple
# Silicon). This is NOT notarization: a *downloaded* copy still needs a one-time
# `xattr -dr com.apple.quarantine trifola.app`.
echo "==> Ad-hoc signing (free; not notarization)…"
codesign --force --sign - "${BUNDLE}" || echo "    (codesign unavailable — skipped; locally-built app still runs)"

echo "==> Done. Built ${BUNDLE}"
echo "    Open with:  open \"${ROOT}/${BUNDLE}\""
