#!/bin/bash
# Remove LaunchAgent + app bundle (current and legacy locations).
set -euo pipefail
NAME="claude-limits"
UID_VAL=$(id -u)

# Tear down all known launch labels.
for L in "${NAME}" "claude-limits-on-menubar" "com.claudelimits.menubar"; do
    launchctl bootout "gui/${UID_VAL}/${L}" >/dev/null 2>&1 || true
done
for BIN_PATTERN in "/Contents/MacOS/${NAME}" "/Contents/MacOS/claude-limits-on-menubar" "/Contents/MacOS/ClaudeLimits"; do
    pkill -f "$BIN_PATTERN" >/dev/null 2>&1 || true
done

# Remove all known plist + bundle paths (current + legacy).
rm -f \
    "$HOME/Library/LaunchAgents/${NAME}.plist" \
    "$HOME/Library/LaunchAgents/claude-limits-on-menubar.plist" \
    "$HOME/Library/LaunchAgents/com.claudelimits.menubar.plist"
rm -rf \
    "$HOME/Applications/${NAME}.app" \
    "$HOME/Applications/claude-limits-on-menubar.app" \
    "$HOME/Applications/ClaudeLimits.app" \
    "$HOME/Applications/Claude Limits on Menubar.app"

echo "Removed ${NAME}."
echo "Settings + history are kept (~/Library/Preferences/${NAME}.plist,"
echo "~/Library/Application Support/${NAME}/) — delete manually to fully reset."
