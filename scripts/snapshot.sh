#!/bin/bash
# Capture current claude-limits visual state into .claude/snapshots/.
# Triggers in-app render via custom URL scheme — no Terminal popups, no
# helper apps, no Screen Recording permission required (the app captures
# its own views via NSView.cacheDisplay, which doesn't need any TCC grant).
#
# Modes:
#   bash scripts/snapshot.sh                    # all (menubar + settings)
#   bash scripts/snapshot.sh --auto-menubar     # menubar only
#   bash scripts/snapshot.sh --auto-settings    # settings only
#   bash scripts/snapshot.sh --auto-all         # alias for default
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.claude/snapshots"
MODE="${1:-interactive}"
mkdir -p "$DEST"

trigger() {
    local kind="$1"
    # Each trigger emits both light + dark; poll on the dark file.
    local watch="$DEST/latest-$kind-dark.png"
    local before
    before=$(stat -f '%m' "$watch" 2>/dev/null || echo 0)
    open "claude-limits://snapshot/$kind?dest=$DEST"
    for _ in $(seq 1 20); do
        local now
        now=$(stat -f '%m' "$watch" 2>/dev/null || echo 0)
        [ "$now" != "$before" ] && return 0
        sleep 0.1
    done
    echo "WARN: $kind capture didn't update $watch" >&2
    return 1
}

case "$MODE" in
    --auto-menubar)  trigger menubar ;;
    --auto-dropdown) trigger dropdown ;;
    --auto-settings) trigger settings ;;
    --auto-all|interactive) trigger menubar; trigger dropdown; trigger settings ;;
    *) echo "Usage: $0 [--auto-menubar|--auto-dropdown|--auto-settings|--auto-all]"; exit 2 ;;
esac

echo "Saved to $DEST. Refresh .claude/snapshots/index.html to view."
