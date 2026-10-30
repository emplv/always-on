#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) "Always On.app" into ./build.
# `./build.sh install` also replaces /Applications/Always On.app and relaunches it.
set -euo pipefail
cd "${0:A:h}"

APP="build/Always On.app"
BIN="$APP/Contents/MacOS/AlwaysOn"
MIN_MACOS=13.0

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" build/obj

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library \
    -target "$arch-apple-macos$MIN_MACOS" \
    Sources/*.swift \
    -o "build/obj/AlwaysOn-$arch"
done

lipo -create build/obj/AlwaysOn-arm64 build/obj/AlwaysOn-x86_64 -output "$BIN"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  if pgrep -x AlwaysOn >/dev/null; then
    osascript -e 'quit app "Always On"'
    while pgrep -x AlwaysOn >/dev/null; do sleep 0.2; done
  fi
  rm -rf "/Applications/Always On.app"
  cp -R "$APP" /Applications/
  open "/Applications/Always On.app"
  echo "Installed and launched /Applications/Always On.app"
fi
