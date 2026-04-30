#!/bin/bash
# Build, package, and stage a release artifact for distribution via brew.
# Run this on macOS — it calls build.sh which uses swiftc + iconutil.
#
# Usage:  bash scripts/release.sh 0.1.0
#
# What it does:
#   1. Runs scripts/build.sh to produce the .app bundle
#   2. Bumps CFBundleShortVersionString in the bundled Info.plist
#   3. Zips the .app into dist/claude-limits-<version>.zip
#   4. Computes SHA256 of the zip
#   5. Updates homebrew/claude-limits.rb in-place with the
#      new version + sha256 (ready to be copied to the tap repo)
#   6. Prints the next manual steps (gh release, tap push)
#
# What it does NOT do (these need explicit approval each time):
#   - git commit / tag / push
#   - gh release create / upload
#   - Touch the homebrew tap's git repo
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.1.0"
    exit 2
fi
VERSION="$1"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/${NAME}-${VERSION}.zip"
CASK_FILE="$ROOT/homebrew/claude-limits.rb"

mkdir -p "$DIST_DIR"

# ── 1. Build ─────────────────────────────────────────────────────────────────
echo "→ Building ${NAME} v${VERSION}…"
bash "$ROOT/scripts/build.sh"

# ── 2. Patch Info.plist with the requested version ───────────────────────────
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
echo "→ Info.plist version → $VERSION"

# Re-codesign after touching the bundle (codesign invalidates on edits).
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

# ── 3. Zip the .app ──────────────────────────────────────────────────────────
echo "→ Zipping .app → $ZIP_PATH"
rm -f "$ZIP_PATH"
# `ditto` preserves macOS metadata + symlinks; this is what Apple recommends
# for distributing app bundles, not plain `zip`.
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# ── 4. SHA256 ────────────────────────────────────────────────────────────────
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
SIZE=$(stat -f '%z' "$ZIP_PATH")
echo "→ SHA256: $SHA256"
echo "→ Size:   ${SIZE} bytes"

# ── 5. Update the cask formula in-place ──────────────────────────────────────
echo "→ Updating $CASK_FILE"
# Cross-platform sed-in-place that works on BSD sed (macOS).
sed -i '' "s|^  version \".*\"|  version \"$VERSION\"|" "$CASK_FILE"
sed -i '' "s|^  sha256 \".*\"|  sha256 \"$SHA256\"|" "$CASK_FILE"
echo "  → version: $(grep '^  version' "$CASK_FILE")"
echo "  → sha256:  $(grep '^  sha256'  "$CASK_FILE")"

# ── 6. Next steps ────────────────────────────────────────────────────────────
cat <<EOF

Release artifact ready.

   File:    $ZIP_PATH
   SHA256:  $SHA256
   Cask:    $CASK_FILE  (updated in-place)

Next manual steps (run these only when you're ready to publish):

  # 1. Commit + tag + push the source repo
  cd "$ROOT"
  git add -A
  git commit -m "v${VERSION}"
  git tag "v${VERSION}"
  git push origin main --tags

  # 2. Create the GitHub Release and upload the zip
  gh release create "v${VERSION}" "$ZIP_PATH" \\
    --title "v${VERSION}" \\
    --notes "Release ${VERSION}"

  # 3. Copy the cask file into your homebrew tap repo, commit, push:
  cp "$CASK_FILE" /path/to/homebrew-lab/Casks/
  cd /path/to/homebrew-lab
  git add -A
  git commit -m "claude-limits ${VERSION}"
  git push

After step 3, anyone can install with:
  brew tap ibrarwtf/lab
  brew install --cask claude-limits

EOF
