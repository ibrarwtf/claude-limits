#!/bin/bash
# Build, package, and publish a release.
#
# Usage:
#   bash scripts/release.sh 0.1.6              # build artifact + patch cask, print next steps
#   bash scripts/release.sh 0.1.6 --publish    # also: tag, push, gh release, tap commit + push
#
# What --publish does that the default doesn't:
#   - git tag v<VERSION> + push tag and main
#   - gh release create with the zip uploaded as the asset
#   - copies the cask file into the homebrew tap clone, commits, pushes
#   - assumes ~/p/homebrew-lab is the tap clone (configurable via TAP_DIR env)
#   - uses release notes from the matching section of CHANGELOG.md if present,
#     otherwise falls back to "Release <VERSION>"
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--publish]"
    echo "Example: $0 0.1.6 --publish"
    exit 2
fi
VERSION="$1"
PUBLISH="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/${NAME}-${VERSION}.zip"
CASK_FILE="$ROOT/homebrew/claude-limits.rb"
TAP_DIR="${TAP_DIR:-$HOME/p/homebrew-lab}"

mkdir -p "$DIST_DIR"

# ── 1. Bump VERSION file (single source of truth) ────────────────────────────
echo "$VERSION" > "$ROOT/VERSION"
echo "→ VERSION → $VERSION"

# ── 2. Build (build.sh reads VERSION → bakes it into Info.plist) ─────────────
echo "→ Building ${NAME} v${VERSION}…"
bash "$ROOT/scripts/build.sh"

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

# ── 6. Resolve release notes (CHANGELOG.md section if present) ───────────────
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
if [[ -f "$ROOT/CHANGELOG.md" ]]; then
    # Pull the section under "## v<VERSION>" up to (but not including) the next "## " header.
    awk -v ver="## v$VERSION" '
        $0 == ver {found=1; next}
        found && /^## / {exit}
        found {print}
    ' "$ROOT/CHANGELOG.md" > "$NOTES_FILE"
fi
if [[ ! -s "$NOTES_FILE" ]]; then
    echo "Release ${VERSION}" > "$NOTES_FILE"
fi

# ── 7. Either print next-steps or run them under --publish ───────────────────
if [[ "$PUBLISH" != "--publish" ]]; then
    cat <<EOF

Release artifact ready (NOT published — re-run with --publish to ship).

   File:    $ZIP_PATH
   SHA256:  $SHA256
   Cask:    $CASK_FILE  (updated in-place)

To publish:
  bash scripts/release.sh ${VERSION} --publish

Or do it manually:

  # 1. Commit + tag + push the source repo
  cd "$ROOT"
  git add -A
  git commit -m "v${VERSION}"
  git tag "v${VERSION}"
  git push origin main --tags

  # 2. Create the GitHub Release and upload the zip
  gh release create "v${VERSION}" "$ZIP_PATH" \\
    --title "v${VERSION}" \\
    --notes-file "$NOTES_FILE"

  # 3. Copy the cask file into your homebrew tap repo, commit, push.
  #    First verify the tap clone is committing as your personal identity —
  #    global git config defaults to your work email and will leak otherwise:
  cd "$TAP_DIR"
  git config user.email   # MUST be your personal address, not a work one
  cp "$CASK_FILE" Casks/
  git add -A
  git commit -m "claude-limits ${VERSION}"
  git push

After step 3, anyone can install with:
  brew tap ibrarwtf/lab
  brew install --cask claude-limits

EOF
    exit 0
fi

# ── --publish path: do it all ────────────────────────────────────────────────
echo ""
echo "→ --publish: tagging + pushing source repo"
cd "$ROOT"
# Stage everything (VERSION, cask, plus whatever else the maintainer queued).
git add -A
# Allow re-running release.sh after a partial failure: skip commit if nothing staged.
if ! git diff --cached --quiet; then
    git commit -m "v${VERSION}"
fi
git tag -f "v${VERSION}"
git push origin main
git push origin "v${VERSION}"

echo ""
echo "→ --publish: creating GitHub release with zip asset"
# Delete any existing release for this tag (idempotent re-run after partial failure).
gh release delete "v${VERSION}" --yes >/dev/null 2>&1 || true
gh release create "v${VERSION}" "$ZIP_PATH" \
    --title "v${VERSION}" \
    --notes-file "$NOTES_FILE"

echo ""
echo "→ --publish: updating homebrew tap at $TAP_DIR"
if [[ ! -d "$TAP_DIR/.git" ]]; then
    echo "ERROR: $TAP_DIR is not a git clone. Set TAP_DIR=/path/to/homebrew-lab and retry." >&2
    exit 3
fi
cd "$TAP_DIR"
TAP_EMAIL="$(git config user.email || true)"
if [[ "$TAP_EMAIL" != *"ibrarwtf"* && "$TAP_EMAIL" != *"@users.noreply.github.com" ]]; then
    echo "ERROR: tap repo is committing as <$TAP_EMAIL> — looks like work identity." >&2
    echo "Run:   git -C \"$TAP_DIR\" config user.email ibrarwtf@users.noreply.github.com" >&2
    exit 4
fi
mkdir -p Casks
cp "$CASK_FILE" Casks/
git add -A
if ! git diff --cached --quiet; then
    git commit -m "claude-limits ${VERSION}"
    git push
else
    echo "  (tap already at v${VERSION} — nothing to push)"
fi

echo ""
echo "✓ Published v${VERSION}."
echo "  Source:  https://github.com/ibrarwtf/claude-limits/releases/tag/v${VERSION}"
echo "  Tap:     https://github.com/ibrarwtf/homebrew-lab"
echo ""
echo "Verify with: brew update && brew info --cask claude-limits"
