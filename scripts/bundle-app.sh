#!/usr/bin/env bash
# Builds the XMBar SwiftPM target and wraps it into build/XMBar.app (ad-hoc signed).
# Usage: scripts/bundle-app.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/XMBar.app"

[[ -f "$ROOT/build/lib/libmdr.a" ]] || "$ROOT/scripts/build-libmdr.sh"

swift build --package-path "$ROOT" -c "$CONFIG" --product XMBar
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/XMBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XMBar"
cp "$ROOT/Sources/XMBar/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and for macOS to remember the Bluetooth permission.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
