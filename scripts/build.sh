#!/bin/bash
# Build "claude-limits.app" into ~/Applications/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="claude-limits"
APP_BUNDLE="$HOME/Applications/${NAME}.app"
BUILD_DIR="$ROOT/build"
SWIFT_SRC="$ROOT/src/main.swift"
ICON_SRC="$ROOT/assets/AppIcon.icns"

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
    "$SWIFT_SRC"

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
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built $APP_BUNDLE"
echo "   binary: $(stat -f '%z bytes' "$APP_BUNDLE/Contents/MacOS/${NAME}")"
echo "   icon:   $(stat -f '%z bytes' "$APP_BUNDLE/Contents/Resources/AppIcon.icns")"
