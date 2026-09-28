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

LOG="$OUT/screens.log"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --screens "http://127.0.0.1:$PORT" -AppleLanguages "(ar)" -AppleLocale ar_SA > "$LOG" 2>&1 &
LAUNCH_PID=$!

seen=" "
for _ in $(seq 1 360); do
    sleep 0.5
    for name in $(grep -o "SCREEN [0-9a-z-]*" "$LOG" | awk '{print $2}'); do
        case "$seen" in *" $name "*) continue ;; esac
        sleep 1.4
        xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "  captured $name"
        seen="$seen$name "
    done
    if grep -q "SCREENS_DONE" "$LOG"; then break; fi
    if ! kill -0 $LAUNCH_PID 2>/dev/null; then
        echo "App exited early:"; tail -40 "$LOG"; break
    fi
done
kill $LAUNCH_PID 2>/dev/null || true
xcrun simctl shutdown "$UDID" 2>/dev/null || true
ls -la "$OUT"
