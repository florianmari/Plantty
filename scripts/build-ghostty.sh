#!/usr/bin/env bash
# Builds GhosttyKit.xcframework + runtime resources into vendor/.
set -euo pipefail
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-e3ebb1d}" # C API is unstable on main; bump deliberately
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/ghostty"

if [[ -d "$VENDOR/GhosttyKit.xcframework" && -d "$VENDOR/share/terminfo" ]]; then
  echo "vendor/ already built; delete vendor/GhosttyKit.xcframework to rebuild"; exit 0
fi

mkdir -p "$VENDOR"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$GHOSTTY_COMMIT"

(cd "$SRC" && zig build -Demit-xcframework=true -Demit-macos-app=false \
  -Dxcframework-target=native -Doptimize=ReleaseFast)

rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/share"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$VENDOR/"
mkdir -p "$VENDOR/share"
cp -R "$SRC/zig-out/share/terminfo" "$SRC/zig-out/share/ghostty" "$VENDOR/share/"
echo "done: $VENDOR"
