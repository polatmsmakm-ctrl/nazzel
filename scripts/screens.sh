#!/bin/bash
# Boots a simulator, runs the app in demo mode and saves screenshots
# plus the rendered paper image, so the build can be checked by eye.
set -uo pipefail
APP="$1"; OUT="$2"
mkdir -p "$OUT"
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for k,v in d.items() if "iOS" in k for x in v if x["name"].startswith("iPhone")]
c.sort(key=lambda x: ("Pro" in x["name"], x["name"]))
print(c[0]["udid"])')
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
BID=com.tahdeer.app
xcrun simctl launch "$UDID" $BID -demo
sleep 8
xcrun simctl io "$UDID" screenshot "$OUT/home.png"
DATA=$(xcrun simctl get_app_container "$UDID" $BID data)
cp "$DATA/Documents/demo.png" "$OUT/paper.png" && echo "paper rendered"
ls -la "$OUT"
