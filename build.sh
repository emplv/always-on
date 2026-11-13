#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) "Always On.app" into ./build.
#   ./build.sh                  # Full build -> build/Always On.app
#   ./build.sh --lite           # Lite build, no lid-closed mode (never asks for admin rights)
#                               #   -> build/lite/Always On.app
#   ./build.sh [--lite] install # also replaces /Applications/Always On.app and relaunches it
set -euo pipefail
cd "${0:A:h}"

LITE=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --lite) LITE=1 ;;
    install) INSTALL=1 ;;
    *) echo "usage: $0 [--lite] [install]" >&2; exit 2 ;;
  esac
done

if (( LITE )); then
  OUT=build/lite
  FLAGS=(-D LITE)
else
  OUT=build
  FLAGS=()
fi
APP="$OUT/Always On.app"
BIN="$APP/Contents/MacOS/AlwaysOn"
OBJ="$OUT/obj"
MIN_MACOS=13.0

rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$OBJ"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library "${FLAGS[@]}" \
    -target "$arch-apple-macos$MIN_MACOS" \
    Sources/*.swift \
    -o "$OBJ/AlwaysOn-$arch"
done

lipo -create "$OBJ/AlwaysOn-arm64" "$OBJ/AlwaysOn-x86_64" -output "$BIN"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"

if (( INSTALL )); then
  if pgrep -x AlwaysOn >/dev/null; then
    osascript -e 'quit app "Always On"'
    while pgrep -x AlwaysOn >/dev/null; do sleep 0.2; done
  fi
  rm -rf "/Applications/Always On.app"
  cp -R "$APP" /Applications/
  open "/Applications/Always On.app"
  echo "Installed and launched /Applications/Always On.app"
fi
