#!/bin/bash
# Remove the dev install (LaunchAgent + ~/Applications bundle).
# With --all, also uninstall the brew cask if present.
#
# Usage:
#   bash scripts/uninstall.sh           # remove dev install only
#   bash scripts/uninstall.sh --all     # remove dev install + brew cask
set -euo pipefail
NAME="claude-limits"
UID_VAL=$(id -u)
ALL_MODE=""
[ "${1:-}" = "--all" ] && ALL_MODE=yes

# ── Stop running instance(s) (matches both ~/Applications and /Applications) ──
launchctl bootout "gui/${UID_VAL}/${NAME}" >/dev/null 2>&1 || true
pkill -f "/Contents/MacOS/${NAME}" >/dev/null 2>&1 || true

# ── Remove dev install: LaunchAgent plist + ~/Applications bundle ────────────
rm -f  "$HOME/Library/LaunchAgents/${NAME}.plist"
rm -rf "$HOME/Applications/${NAME}.app"

if [ -n "$ALL_MODE" ]; then
    if command -v brew >/dev/null 2>&1 && brew list --cask 2>/dev/null | grep -q "^${NAME}$"; then
        echo "→ --all: brew uninstalling cask"
        brew uninstall --cask "${NAME}" || true
    fi
fi

echo ""
echo "Removed dev install (${NAME}.app at ~/Applications + LaunchAgent plist)."
[ -n "$ALL_MODE" ] && echo "Brew cask also removed (--all)."
echo ""
echo "Kept: settings (~/Library/Preferences/${NAME}.plist),"
echo "      history (~/Library/Application Support/${NAME}/) — delete manually to fully reset."
[ -z "$ALL_MODE" ] && [ -d "/Applications/${NAME}.app" ] && \
    echo "      brew install at /Applications/${NAME}.app — run with --all to remove that too."
