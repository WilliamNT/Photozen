#!/bin/bash
set -euo pipefail

# macOS `open` does not relaunch an app that's already running — it only
# brings the OLD process (with the OLD code) to the front. Quit any live
# instance first so you always see the build that's on disk.
if pgrep -x Photozen >/dev/null 2>&1; then
    osascript -e 'tell application id "com.photozen.app" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Photozen >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -x Photozen 2>/dev/null || true
fi

open build/Photozen.app
