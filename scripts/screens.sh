#!/bin/bash
# Launches the app in "screens" mode on a simulator and saves a screenshot of every screen.
#   scripts/screens.sh <App.app> <device-name-pattern> <out-dir>
set -uo pipefail

APP="$1"
PATTERN="${2:-iPhone}"
OUT="${3:-screens}"
BUNDLE_ID="${BUNDLE_ID:-com.nazzel.app}"
PORT=8766
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"

python3 "$ROOT/ci/serve.py" "$PORT" "$ROOT/ci/media" >/tmp/screens-http.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

UDID="$(xcrun simctl list devices available -j | PATTERN="$PATTERN" python3 -c '
import json, os, sys
pattern = os.environ["PATTERN"]
best = None
for runtime, devs in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devs:
        if d.get("isAvailable") and pattern in d["name"]:
            best = (d["udid"], d["name"])
print(best[0] if best else "")
')"
if [ -z "$UDID" ]; then
    echo "No simulator matching '$PATTERN'"
    exit 0
fi
echo "Screens on $PATTERN ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
# make sure the media server answers before the app starts downloading
for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/dash/manifest.mpd" && break
    sleep 1
done

LOG="$OUT/screens.log"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --screens "http://127.0.0.1:$PORT" -AppleLanguages "(ar)" -AppleLocale ar_SA > "$LOG" 2>&1 &
LAUNCH_PID=$!

# The app photographs itself; wait until it is done (or dies).
for _ in $(seq 1 240); do
    sleep 1
    if grep -q "SCREENS_DONE" "$LOG"; then break; fi
    if ! kill -0 $LAUNCH_PID 2>/dev/null; then
        echo "App exited early:"; break
    fi
done
kill $LAUNCH_PID 2>/dev/null || true
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)"
cp "$DATA/Library/Caches/Nazzel/screens/"*.png "$OUT/" 2>/dev/null || echo "no in-app screenshots"
echo "--- app log (tail) ---"
grep -v "NAZZEL_SELFTEST: \[.*\] log " "$LOG" | tail -60
xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'process == "Nazzel" AND (messageType == error OR messageType == fault)' 2>/dev/null | tail -40 > "$OUT/system.log" || true
xcrun simctl shutdown "$UDID" 2>/dev/null || true
ls -la "$OUT"
