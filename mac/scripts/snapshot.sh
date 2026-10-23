#!/bin/bash
# Render the Mac UI from spec/fixtures/snapshot.json (CI: snapshots/mac/, local: build/snapshots/mac/).
#
# Runs the built binary in fixture mode (canned response, pinned clock, no
# network, no settings/history writes), which captures menubar + dropdown +
# settings in light + dark and exits. Same images on every machine and in CI.
#
#   bash mac/scripts/snapshot.sh            # uses ~/Applications/claude-limits.app
#   APP_BUNDLE=/path/to/x.app bash mac/scripts/snapshot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$HOME/Applications/claude-limits.app}"
# CI writes the committed PNGs; local renders go under build/ so font and
# encoder differences between machines don't churn snapshots/.
if [ -n "${CI:-}" ]; then DEST="$ROOT/snapshots/mac"; else DEST="$ROOT/build/snapshots/mac"; fi
mkdir -p "$DEST"

"$APP_BUNDLE/Contents/MacOS/claude-limits" \
    --fixture "$ROOT/spec/fixtures/snapshot.json" \
    --snapshot-all "$DEST" &
pid=$!
# Fixture capture takes ~1s; don't hang CI if the window server misbehaves.
for _ in $(seq 1 300); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "ERROR: snapshot render timed out" >&2
    exit 1
fi
wait "$pid"

echo "Saved to $DEST."
