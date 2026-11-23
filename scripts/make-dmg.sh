#!/usr/bin/env bash
# Packages an app bundle into a compressed DMG (app + Applications symlink).
# Usage: scripts/make-dmg.sh <path/to/XMBar.app> <output.dmg>
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <path/to/XMBar.app> <output.dmg>" >&2; exit 64; }
APP="$1"
DMG="$2"
[[ -d "$APP" ]] || { echo "not a directory: $APP" >&2; exit 1; }

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/xmbar-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "XMBar" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
echo "Built $DMG"
