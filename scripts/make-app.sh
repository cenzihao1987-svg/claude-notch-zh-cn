#!/usr/bin/env bash
# Build "Claude Notch.app" and a shareable zip from the SwiftPM package.
#
#   bash scripts/make-app.sh
#
# Signing:
#   • Auto-uses a "Developer ID Application" identity if one is in your keychain,
#     otherwise falls back to ad-hoc ("-"). Override with SIGN_ID="…".
# Notarizing (removes the "unverified developer" warning for other users):
#   • Set up once:  xcrun notarytool store-credentials "claude-notch-notary" \
#                       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#   • Then:  NOTARY_PROFILE=claude-notch-notary bash scripts/make-app.sh
set -euo pipefail

# Full Xcode required (SwiftUI macros). Honor an explicit DEVELOPER_DIR, else use the selected
# toolchain, else fall back to a standard Xcode install (beta last).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  case "$DEVELOPER_DIR" in
    *CommandLineTools*|"")
      for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$x/Contents/Developer" ]; then DEVELOPER_DIR="$x/Contents/Developer"; break; fi
      done ;;
  esac
fi
export DEVELOPER_DIR
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Claude Notch"
DIST="$ROOT/dist"
APPDIR="$DIST/$APP_NAME.app"

# Pick a signing identity.
# LOCAL_SIGN=1 marks an identity Apple never issued (self-signed or ad-hoc): no hardened runtime,
# no timestamp, no WidgetKit — see the signing step below.
LOCAL_SIGN=0
LOCAL_CERT_NAME="${LOCAL_CERT_NAME:-Claude Notch Local}"
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  if [ -z "$SIGN_ID" ]; then
    # A self-signed code-signing certificate is enough to make the designated requirement stable
    # across rebuilds ("certificate leaf = H…" instead of a cdhash), which is what keeps the
    # Keychain "Always Allow" grants alive. Free, and good enough for a local build.
    SIGN_ID="$(security find-identity -v -p codesigning \
      | awk -F'"' -v n="$LOCAL_CERT_NAME" '$2 == n {print $2; exit}')"
    if [ -n "$SIGN_ID" ]; then
      LOCAL_SIGN=1
      echo "▸ No Developer ID — using self-signed '$SIGN_ID' (LOCAL BUILD ONLY, do not distribute)"
    fi
  fi
  if [ -z "$SIGN_ID" ]; then
    # Ad-hoc signing gives the app a cdhash-based designated requirement, so every rebuild is a
    # DIFFERENT identity to macOS: users' "Always Allow" Keychain grants stop applying and the
    # authorization prompt returns after each update (issue #6). Never ship that by accident.
    if [ -n "${ALLOW_ADHOC:-}" ]; then
      echo "⚠︎ No Developer ID identity — ad-hoc signing (LOCAL BUILD ONLY, do not distribute)"
      echo "  Every rebuild re-prompts for the Keychain password. Create a self-signed"
      echo "  '$LOCAL_CERT_NAME' code-signing certificate to stop that."
      SIGN_ID="-"
      LOCAL_SIGN=1
    else
      echo "✗ No 'Developer ID Application' identity found in the keychain."
      echo "  Releases must be signed with a stable identity, or users get repeated Keychain"
      echo "  prompts after every update. Set SIGN_ID=… or re-run with ALLOW_ADHOC=1 for a"
      echo "  throwaway local build."
      exit 1
    fi
  fi
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
EMBED_WIDGETKIT="${EMBED_WIDGETKIT:-0}"
if [ "$EMBED_WIDGETKIT" = "1" ] && [ "$LOCAL_SIGN" = "1" ]; then
  echo "✗ WidgetKit extensions require an Apple signing identity; use the built-in desktop widget for local builds."
  exit 1
fi

echo "▸ Release build…"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/ClaudeNotch"
WIDGET_BIN="$ROOT/.build/release/CodexQuotaWidget"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }
if [ "$EMBED_WIDGETKIT" = "1" ]; then
  [ -x "$WIDGET_BIN" ] || { echo "✗ widget binary not found at $WIDGET_BIN"; exit 1; }
fi

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$DIST"
WIDGET_APP="$APPDIR/Contents/PlugIns/CodexQuotaWidget.appex"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Frameworks"
cp "$BIN" "$APPDIR/Contents/MacOS/ClaudeNotch"
cp "$ROOT/Resources/Info.plist" "$APPDIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/CodexWidgetShared/Resources/codex-widget-icon.png" \
  "$APPDIR/Contents/Resources/codex-widget-icon.png"
if [ "$EMBED_WIDGETKIT" = "1" ]; then
  mkdir -p "$WIDGET_APP/Contents/MacOS" "$WIDGET_APP/Contents/Resources"
  cp "$WIDGET_BIN" "$WIDGET_APP/Contents/MacOS/CodexQuotaWidget"
  cp "$ROOT/Resources/CodexQuotaWidget-Info.plist" "$WIDGET_APP/Contents/Info.plist"
  cp "$ROOT/Sources/CodexWidgetShared/Resources/codex-widget-icon.png" \
    "$WIDGET_APP/Contents/Resources/codex-widget-icon.png"
fi

# Preserve SwiftPM's resource bundle inside the conventional app resources directory.
# Resolved via the same .build/release products path as BIN above — SwiftPM keeps that as a
# symlink into the real products dir on every toolchain layout, whereas find(1) won't follow
# the symlink and misses the bundle on toolchains that build into .build/out/Products/Release.
RESOURCE_BUNDLE="$ROOT/.build/release/ClaudeNotch_ClaudeNotch.bundle"
[ -d "$RESOURCE_BUNDLE" ] || { echo "✗ ClaudeNotch resource bundle not found at $RESOURCE_BUNDLE"; exit 1; }
ditto "$RESOURCE_BUNDLE" "$APPDIR/Contents/Resources/ClaudeNotch_ClaudeNotch.bundle"

# Embed Sparkle.framework (SwiftPM builds it as an xcframework) + let the binary find it.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -path "*macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)"
[ -d "$SPARKLE_FW" ] || { echo "✗ Sparkle.framework not found — run 'swift build' first"; exit 1; }
ditto "$SPARKLE_FW" "$APPDIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/ClaudeNotch" 2>/dev/null || true

echo "▸ Signing as: $SIGN_ID"
FW="$APPDIR/Contents/Frameworks/Sparkle.framework"
if [ "$LOCAL_SIGN" = "1" ]; then
  # Plain signing, deliberately without --options runtime: the hardened runtime turns on library
  # validation, which matches loadable frameworks by team identifier — and an identity Apple
  # didn't issue has none, so the embedded Sparkle.framework would fail to load. --timestamp is
  # skipped too; it calls out to Apple's timestamp server and buys nothing for a local build.
  codesign --force --sign "$SIGN_ID" "$FW"
  codesign --force --sign "$SIGN_ID" "$APPDIR"
else
  # Sign Sparkle inside-out (no --deep), then the app last.
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/XPCServices/Installer.xpc"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/Autoupdate"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/Updater.app"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW"
  if [ "$EMBED_WIDGETKIT" = "1" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
      --entitlements "$ROOT/Resources/CodexQuotaWidget.entitlements" "$WIDGET_APP"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
      --entitlements "$ROOT/Resources/ClaudeNotch.entitlements" "$APPDIR"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APPDIR"
  fi
  codesign --verify --strict --verbose=2 "$APPDIR"
fi

if [ -n "$NOTARY_PROFILE" ] && [ "$LOCAL_SIGN" != "1" ]; then
  echo "▸ Notarizing (this uploads to Apple and waits)…"
  ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$DIST/notary.zip"
  xcrun notarytool submit "$DIST/notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APPDIR"
  rm -f "$DIST/notary.zip"
  xcrun stapler validate "$APPDIR" && echo "  ✓ stapled + valid"
fi

echo "▸ Zipping (ditto, signature-safe)…"
ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$DIST/ClaudeNotch.zip"

echo "✓ Done:"
echo "   app: $APPDIR"
echo "   zip: $DIST/$APP_NAME.zip"
[ -n "$NOTARY_PROFILE" ] && echo "   (signed + notarized)" || echo "   (signed: $SIGN_ID)"
