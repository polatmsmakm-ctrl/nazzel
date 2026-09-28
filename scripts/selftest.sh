#!/bin/bash
# Boots an iOS simulator, installs the simulator build and runs the in-app
# self-test: embedded Python, HTTPS, yt-dlp, WebKit JS, real downloads from a
# local server, and the native AVFoundation merge.
set -euo pipefail

APP="$1"
BUNDLE_ID="${BUNDLE_ID:-com.nazzel.app}"
PORT=8765
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 12 MB test file for the turbo check; the server caps each connection at 1 MB/s
head -c 12582912 /dev/urandom > "$ROOT/ci/media/big.mp4"
SERVE_RATE=1048576 python3 "$ROOT/ci/serve.py" "$PORT" "$ROOT/ci/media" >/tmp/http.log 2>&1 &
SERVER_PID=$!
sleep 1
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in data.items():
    if "iOS" not in runtime:
        continue
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            best = d["udid"]
print(best or "")
')"
if [ -z "$UDID" ]; then
    echo "No iPhone simulator available"; xcrun simctl list devices; exit 1
fi
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"

set +e
# perl alarm = portable timeout on macOS
perl -e 'alarm shift; exec @ARGV' 900 \
    xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --selftest "http://127.0.0.1:$PORT" 2>&1 | tee selftest.log
set -e

if grep -Eq "NAZZEL_SELFTEST: (\[[ 0-9.]+s\] )?RESULT PASS" selftest.log; then
    echo "Self-test passed"
else
    echo "Self-test FAILED"
    xcrun simctl spawn "$UDID" log show --last 5m --predicate 'process == "Nazzel"' --style compact 2>/dev/null | tail -200 || true
    exit 1
fi
