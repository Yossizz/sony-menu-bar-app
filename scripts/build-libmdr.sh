#!/usr/bin/env bash
# Builds libmdr (protocol) + libmdr-bt (macOS IOBluetooth backend) from the pinned
# vendor/SonyHeadphonesClient submodule into build/lib, for SwiftPM to link.
# Requires: cmake >= 3.31, ninja (brew install cmake ninja).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/SonyHeadphonesClient"
BUILD="$ROOT/build/libmdr"
OUT="$ROOT/build/lib"
CONFIG="${CONFIG:-Release}"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  git -C "$ROOT" submodule update --init vendor/SonyHeadphonesClient
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DMDR_BUILD_CLIENT=OFF \
  -DMDR_BUILD_TESTING=OFF \
  -DMDR_BUILD_CODEGEN=OFF \
  -DMDR_BUILD_WITH_IPO=OFF \
  -DMDR_BT_BLE_SUPPORT=OFF

cmake --build "$BUILD" --target mdr mdr-bt fmt

mkdir -p "$OUT"
for lib in libmdr.a libmdr-bt.a libfmt.a; do
  found="$(find "$BUILD" -name "$lib" -print -quit)"
  [[ -n "$found" ]] || { echo "missing $lib" >&2; exit 1; }
  cp "$found" "$OUT/"
done
echo "Built: $(ls "$OUT")"
