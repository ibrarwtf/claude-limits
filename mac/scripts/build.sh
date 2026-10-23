#!/bin/bash
# Build "claude-limits.app" into ~/Applications/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
BUILD_DIR="$ROOT/build/mac"
ICON_SRC="$ROOT/assets/AppIcon.icns"

# Single source of truth — release.sh writes here, build.sh reads from here.
# Means a casual `bash scripts/install.sh` after a release always builds the
# current version, not whatever was hardcoded into a heredoc.
VERSION="$(cat "$ROOT/VERSION" | tr -d '[:space:]')"

# Boundary check: mac/core/* must be Foundation-only — the spec tests
# (mac/tests/) compile it on its own, without AppKit.
if grep -l "import AppKit\|import Cocoa" "$ROOT/mac/core/"*.swift 2>/dev/null; then
    echo "ERROR: AppKit/Cocoa imports found in mac/core/ — core must stay headless." >&2
    exit 2
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# Icon is pre-baked at assets/AppIcon.icns; the build just copies it.
echo "→ Copying icon…"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# ── Compile Swift ───────────────────────────────────────────────────────────
echo "→ Compiling Swift…"
swiftc -O \
    -framework AppKit -framework Foundation \
    -o "$BUILD_DIR/${NAME}" \
    "$ROOT/mac/core/"*.swift "$ROOT/mac/app/"*.swift

cp "$BUILD_DIR/${NAME}" "$APP_BUNDLE/Contents/MacOS/${NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${NAME}"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${NAME}</string>
    <key>CFBundleExecutable</key>      <string>${NAME}</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${NAME}</string>
            <key>CFBundleURLSchemes</key>
            <array><string>claude-limits</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built $APP_BUNDLE"
echo "   binary: $(stat -f '%z bytes' "$APP_BUNDLE/Contents/MacOS/${NAME}")"
echo "   icon:   $(stat -f '%z bytes' "$APP_BUNDLE/Contents/Resources/AppIcon.icns")"
