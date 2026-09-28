#!/bin/bash
# Wraps a built .app into an unsigned .ipa for sideloading
# (AltStore, SideStore, Sideloadly, TrollStore, eSign, ...).
set -euo pipefail

APP="$1"
OUT="$2"

[ -d "$APP" ] || { echo "App not found: $APP"; exit 1; }
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
APP_NAME="$(basename "$APP")"

# Remove anything a sideload tool would choke on.
find "$STAGE/Payload/$APP_NAME" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
find "$STAGE/Payload/$APP_NAME" -name ".DS_Store" -delete

# Ad-hoc sign nested frameworks and the app so TrollStore-style installers
# accept it as-is. Normal sideload tools replace this with your own signature.
if command -v codesign >/dev/null; then
    for fw in "$STAGE/Payload/$APP_NAME"/Frameworks/*.framework; do
        codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1 || true
    done
    codesign --force --sign - --timestamp=none "$STAGE/Payload/$APP_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
(cd "$STAGE" && zip -qry "$OUT_ABS" Payload)
rm -rf "$STAGE"

echo "IPA: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Frameworks: $(unzip -l "$OUT" | grep -c '\.framework/Info.plist' || true)"
