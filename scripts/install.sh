#!/bin/bash
# Build, install, and start the LaunchAgent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/${NAME}"
PLIST_LABEL="${NAME}"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
PLIST_SRC="$ROOT/launchd/${PLIST_LABEL}.plist"

bash "$ROOT/scripts/build.sh"

echo "→ Stopping any running instance (current + legacy names)…"
UID_VAL=$(id -u)
# Tear down all known LaunchAgent labels (current + previous naming schemes)
# so an old install doesn't keep restarting the wrong binary.
for L in "${PLIST_LABEL}" "claude-limits-on-menubar" "com.claudelimits.menubar"; do
    launchctl bootout "gui/${UID_VAL}/${L}" >/dev/null 2>&1 || true
done
for BIN_PATTERN in "/Contents/MacOS/${NAME}" "/Contents/MacOS/claude-limits-on-menubar" "/Contents/MacOS/ClaudeLimits"; do
    pkill -f "$BIN_PATTERN" >/dev/null 2>&1 || true
done

for i in 1 2 3 4 5; do
    if ! pgrep -f "/Contents/MacOS/${NAME}" >/dev/null && \
       ! pgrep -f "/Contents/MacOS/claude-limits-on-menubar" >/dev/null && \
       ! pgrep -f "/Contents/MacOS/ClaudeLimits" >/dev/null; then break; fi
    sleep 1
done
for BIN_PATTERN in "/Contents/MacOS/${NAME}" "/Contents/MacOS/claude-limits-on-menubar" "/Contents/MacOS/ClaudeLimits"; do
    pkill -9 -f "$BIN_PATTERN" >/dev/null 2>&1 || true
done

# Remove legacy bundles + plists from previous naming schemes.
for LEGACY in \
    "$HOME/Applications/ClaudeLimits.app" \
    "$HOME/Applications/Claude Limits on Menubar.app" \
    "$HOME/Applications/claude-limits-on-menubar.app" \
    "$HOME/Library/LaunchAgents/com.claudelimits.menubar.plist" \
    "$HOME/Library/LaunchAgents/claude-limits-on-menubar.plist"; do
    if [ -e "$LEGACY" ] && [ "$LEGACY" != "$APP_BUNDLE" ] && [ "$LEGACY" != "$PLIST_DST" ]; then
        echo "→ Removing legacy: $LEGACY"
        rm -rf "$LEGACY"
    fi
done

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
else
    echo "WARN: process didn't start — check /tmp/claude-limits.log"
fi
