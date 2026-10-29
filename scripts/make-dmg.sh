#!/usr/bin/env bash
# Package a built "Claude Notch.app" into the drag-to-install DMG attached to every GitHub Release.
#
#   bash scripts/make-dmg.sh                      # uses dist/Claude Notch.app from make-app.sh
#   bash scripts/make-dmg.sh "/path/Claude Notch.app"
#
# Output: ClaudeNotch-v<version>.dmg next to the app, containing the app and an Applications link.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Claude Notch.app}"
[ -d "$APP" ] || { echo "✗ $APP not found — run scripts/make-app.sh first"; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "✗ $APP signature is invalid"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$(cd "$(dirname "$APP")" && pwd)/ClaudeNotch-v$VERSION.dmg"
STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGE" "$MOUNT"; }
trap cleanup EXIT

echo "▸ Staging v$VERSION…"
ditto "$APP" "$STAGE/Claude Notch.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $(basename "$DMG")…"
rm -f "$DMG"
hdiutil create -volname "Claude Notch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

# What users drag out of the DMG must still carry a valid signature.
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
codesign --verify --deep --strict "$MOUNT/Claude Notch.app"
[ -L "$MOUNT/Applications" ] || { echo "✗ Applications link missing"; exit 1; }
hdiutil detach "$MOUNT" -quiet

echo "✓ Done: $DMG"
shasum -a 256 "$DMG"
