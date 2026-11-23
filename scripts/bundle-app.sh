#!/usr/bin/env bash
# Builds the XMBar SwiftPM target and wraps it into build/XMBar.app (ad-hoc signed).
# Usage: scripts/bundle-app.sh [debug|release]   (default: release)
# Optional env:
#   VERSION=0.3.0     stamp CFBundleShortVersionString=VERSION and CFBundleVersion=<commit count>
#                     into the bundled Info.plist (the source plist is never modified)
#   SCRATCH_PATH=dir  SwiftPM build directory (default: SwiftPM's .build)
#   OUT_DIR=dir       where XMBar.app is written (default: build/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP="$OUT_DIR/XMBar.app"

SWIFT_ARGS=(--package-path "$ROOT" -c "$CONFIG")
[[ -n "${SCRATCH_PATH:-}" ]] && SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH")

[[ -f "$ROOT/build/lib/libmdr.a" ]] || "$ROOT/scripts/build-libmdr.sh"

swift build "${SWIFT_ARGS[@]}" --product XMBar
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/XMBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XMBar"
cp "$ROOT/Sources/XMBar/Info.plist" "$APP/Contents/Info.plist"
# Apache-2.0 requires LICENSE and NOTICE with every copy; libmdr/{fmt} (MIT) require their notices too.
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

if [[ -n "${VERSION:-}" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
  echo "Stamped version $VERSION ($BUILD_NUMBER)"
fi

# Ad-hoc signature: enough to run locally and for macOS to remember the Bluetooth permission.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
