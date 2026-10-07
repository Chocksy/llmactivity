#!/bin/bash
# Package LLMActivity.app into a compressed DMG with an /Applications symlink.
# With SIGN_ID it signs the DMG; with ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID
# (an App Store Connect API key) it also notarizes and staples it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="LLMActivity.app"
DMG="LLMActivity-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/make-app.sh first" >&2
    exit 1
fi

echo "==> staging"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname LLMActivity -srcfolder "$STAGE" -ov -format UDZO "$DMG" | sed 's/^/    /'

if [ -n "${SIGN_ID:-}" ]; then
    echo "==> codesign DMG"
    codesign --force --timestamp -s "$SIGN_ID" "$DMG"
fi

if [ -n "${ASC_KEY_PATH:-}" ]; then
    echo "==> notarize (waits for Apple)"
    xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
fi

echo "==> done: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
