#!/usr/bin/env bash
# Build a release binary and assemble a validated, double-clickable app in dist/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BIN_NAME="Trifola"
BUNDLE="$ROOT/dist/trifola.app"
PLIST="$BUNDLE/Contents/Info.plist"
ICON_NAME="Trifola.icns"

if [[ ! -f "$ROOT/VERSION" ]]; then
  echo "error: VERSION is missing" >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be numeric major.minor.patch (got '$VERSION')" >&2
  exit 1
fi

# Keep every SwiftPM/compiler support write inside the ignored build tree. This
# makes the one-command assembler work in restricted CI/sandboxes where the
# user's Library and ~/.cache are deliberately read-only.
BUILD_SUPPORT="${TRIFOLA_BUILD_SUPPORT_ROOT:-$ROOT/.build/make-app-support}"
mkdir -p "$BUILD_SUPPORT/cache" "$BUILD_SUPPORT/config" \
  "$BUILD_SUPPORT/security" "$BUILD_SUPPORT/clang" "$BUILD_SUPPORT/swift"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_SUPPORT/clang}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$BUILD_SUPPORT/swift}"
SWIFTPM_PATH_ARGS=(
  --cache-path "$BUILD_SUPPORT/cache"
  --config-path "$BUILD_SUPPORT/config"
  --security-path "$BUILD_SUPPORT/security"
)

# --show-bin-path only resolves SwiftPM's destination; the following command is
# the single release build. Keeping both on one configuration avoids the old
# build → rebuild → query cycle.
BIN_DIR="$(swift build -c release --disable-sandbox \
  "${SWIFTPM_PATH_ARGS[@]}" --show-bin-path)"
echo "==> Building Trifola $VERSION (release)…"
swift build -c release --disable-sandbox \
  "${SWIFTPM_PATH_ARGS[@]}" --product "$BIN_NAME"
BIN_PATH="$BIN_DIR/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trifola-assets.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
ICONSET="$TMP_ROOT/Trifola.iconset"
mkdir -p "$ICONSET"

echo "==> Rendering canonical iconset + docs banner…"
"$BIN_PATH" --render-icon "$ICONSET"

required_icons=(
  icon_16x16.png icon_16x16@2x.png
  icon_32x32.png icon_32x32@2x.png
  icon_128x128.png icon_128x128@2x.png
  icon_256x256.png icon_256x256@2x.png
  icon_512x512.png icon_512x512@2x.png
)
for icon in "${required_icons[@]}"; do
  if [[ ! -s "$ICONSET/$icon" ]]; then
    echo "error: renderer did not produce $icon" >&2
    exit 1
  fi
done
if [[ ! -s "$ROOT/docs/assets/banner.png" ]]; then
  echo "error: renderer did not produce docs/assets/banner.png" >&2
  exit 1
fi

echo "==> Assembling ${BUNDLE#$ROOT/}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$BIN_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$BIN_NAME"

ICON_PATH="$BUNDLE/Contents/Resources/$ICON_NAME"
ICONUTIL_LOG="$TMP_ROOT/iconutil.log"
if ! /usr/bin/iconutil -c icns "$ICONSET" -o "$ICON_PATH" \
  2>"$ICONUTIL_LOG"; then
  # macOS 26.2's iconutil currently rejects complete ten-raster iconsets,
  # including iconsets that the same binary just extracted from Apple's own
  # .icns files. Keep iconutil as the primary path, but retain a deterministic
  # built-in fallback so packaging is not broken by that host-tool regression.
  echo "    note: iconutil rejected a dimension-validated iconset; using lossless ICNS fallback"
  sed 's/^/    iconutil: /' "$ICONUTIL_LOG" >&2
  rm -f "$ICON_PATH"
  # ICNS is a typed big-endian container. Preserve all ten PNG representations
  # (including the 1024px Retina master) instead of accepting sips' one-size
  # conversion. The icon types below are Apple's standard iconset mapping.
  /usr/bin/python3 - "$ICONSET" "$ICON_PATH" <<'PY'
from pathlib import Path
import struct
import sys

source, destination = map(Path, sys.argv[1:])
entries = [
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
]
chunks = []
for icon_type, filename in entries:
    png = (source / filename).read_bytes()
    chunks.append(icon_type + struct.pack(">I", len(png) + 8) + png)
payload = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
fi
if [[ "$(/usr/bin/sips -g format "$ICON_PATH" 2>/dev/null \
  | awk '/format:/ { print $2 }')" != "icns" ]]; then
  echo "error: packaged icon is not a valid ICNS file" >&2
  exit 1
fi
VALIDATED_ICONSET="$TMP_ROOT/Validated.iconset"
/usr/bin/iconutil -c iconset "$ICON_PATH" -o "$VALIDATED_ICONSET"
for icon in "${required_icons[@]}"; do
  if [[ ! -s "$VALIDATED_ICONSET/$icon" ]]; then
    echo "error: packaged ICNS lost $icon" >&2
    exit 1
  fi
done

cat > "$PLIST" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_NAME}</string>
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

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc signing (free; not notarization)…"
/usr/bin/codesign --force --sign - "$BUNDLE"

echo "==> Validating signature, plist, version and icon…"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE"
/usr/bin/plutil -lint "$PLIST"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"
}

[[ "$(plist_value CFBundleExecutable)" == "$BIN_NAME" ]] || {
  echo "error: CFBundleExecutable does not match $BIN_NAME" >&2
  exit 1
}
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" ]] || {
  echo "error: CFBundleShortVersionString does not match VERSION" >&2
  exit 1
}
[[ "$(plist_value CFBundleVersion)" == "$VERSION" ]] || {
  echo "error: CFBundleVersion does not match VERSION" >&2
  exit 1
}
[[ "$(plist_value CFBundleIconFile)" == "$ICON_NAME" ]] || {
  echo "error: CFBundleIconFile does not match $ICON_NAME" >&2
  exit 1
}
[[ -s "$BUNDLE/Contents/Resources/$ICON_NAME" ]] || {
  echo "error: packaged icon is missing or empty" >&2
  exit 1
}
MCP_INIT_JSON="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | "$BUNDLE/Contents/MacOS/$BIN_NAME" --mcp 2>/dev/null)"
[[ "$MCP_INIT_JSON" == *"\"version\":\"$VERSION\""* ]] || {
  echo "error: MCP server version does not match VERSION" >&2
  exit 1
}

echo "==> Done. Built ${BUNDLE#$ROOT/}"
echo "    Open with:  open \"$BUNDLE\""
