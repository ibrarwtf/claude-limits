#!/bin/bash
# Build, install, start the LaunchAgent, and refresh repo snapshots.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/${NAME}"
PLIST_LABEL="${NAME}"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
PLIST_SRC="$ROOT/launchd/${PLIST_LABEL}.plist"

bash "$ROOT/scripts/build.sh"

echo "→ Stopping any running instance…"
UID_VAL=$(id -u)
launchctl bootout "gui/${UID_VAL}/${PLIST_LABEL}" >/dev/null 2>&1 || true
pkill -f "/Contents/MacOS/${NAME}" >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
    pgrep -f "/Contents/MacOS/${NAME}" >/dev/null || break
    sleep 1
done
pkill -9 -f "/Contents/MacOS/${NAME}" >/dev/null 2>&1 || true

echo "→ Installing LaunchAgent → $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|${APP_BIN}|g" "$PLIST_SRC" > "$PLIST_DST"

echo "→ Bootstrapping…"
launchctl bootstrap "gui/${UID_VAL}" "$PLIST_DST"
launchctl kickstart -k "gui/${UID_VAL}/${PLIST_LABEL}"

sleep 2
n=$(pgrep -f "/Contents/MacOS/${NAME}" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -eq 1 ]; then
    echo "'${NAME}' is running. Look for it in your menu bar."
    echo "Logs: tail -f /tmp/claude-limits.log"
elif [ "$n" -gt 1 ]; then
    echo "WARN: multiple instances detected ($n). Check 'pgrep -fa ${NAME}'."
    exit 0
else
    echo "WARN: process didn't start — check /tmp/claude-limits.log"
    exit 0
fi

# Refresh repo snapshots so the working tree always reflects the just-built UI.
# Snapshot capture failure ≠ install failure — log and continue.
echo "→ Refreshing snapshots/…"
bash "$ROOT/scripts/snapshot.sh" --auto-all || \
    echo "  (snapshot capture failed; install itself succeeded)"
