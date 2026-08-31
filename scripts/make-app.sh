#!/bin/bash
# Build LLMActivity.app (ad-hoc signed) from the SPM executable.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="LLMActivity.app"
BIN=".build/release/LLMActivity"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP (v$VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LLMActivity"

sed "s/__VERSION__/$VERSION/g" scripts/Info.plist.template > "$APP/Contents/Info.plist"

echo "==> building app icon from assets/icon-1024.png"
MASTER="assets/icon-1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz"         "$MASTER" --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --deep -s - "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $(pwd)/$APP"
