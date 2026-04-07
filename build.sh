#!/bin/bash
set -e

echo "🔨 Building ImHear..."
swift build -c release 2>&1

APP_DIR="$HOME/Applications/ImHear.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 Creating app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp .build/release/ImHear "$MACOS_DIR/"

# Generate .icns from icon.png
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/icon.png" ]; then
    echo "🎨 Generating app icon..."
    ICONSET="$SCRIPT_DIR/.build/ImHear.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_16x16.png"      > /dev/null
    sips -z 32 32     "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_16x16@2x.png"   > /dev/null
    sips -z 32 32     "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_32x32.png"      > /dev/null
    sips -z 64 64     "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_32x32@2x.png"   > /dev/null
    sips -z 128 128   "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_128x128.png"    > /dev/null
    sips -z 256 256   "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_256x256.png"    > /dev/null
    sips -z 512 512   "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_512x512.png"    > /dev/null
    sips -z 1024 1024 "$SCRIPT_DIR/icon.png" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET"
fi

cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ImHear</string>
    <key>CFBundleDisplayName</key>
    <string>ImHear</string>
    <key>CFBundleIdentifier</key>
    <string>com.custom.imhear</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>ImHear</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ImHear needs microphone access to detect nearby speech and automatically control your media.</string>
</dict>
</plist>
PLIST

cat > /tmp/ImHear.entitlements << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

if [[ "$1" == "--release" ]]; then
    SIGN_IDENTITY="CA2754626BC60B9C14EB5D1309916BE3997C859C"
    echo "🔏 Signing with Developer ID..."
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements /tmp/ImHear.entitlements "$APP_DIR"

    ZIP_PATH="$(pwd)/ImHear.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

    echo "📤 Submitting for notarization..."
    SUBMIT_OUT=$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "ImHear-Notary" 2>&1)
    echo "$SUBMIT_OUT"
    SUBMISSION_ID=$(echo "$SUBMIT_OUT" | grep "id:" | head -1 | awk '{print $2}')

    echo ""
    echo "⏳ Notarization submitted! Check status with:"
    echo "   xcrun notarytool info $SUBMISSION_ID --keychain-profile \"ImHear-Notary\""
    echo ""
    echo "When status is 'Accepted', run:"
    echo "   xcrun stapler staple \"$APP_DIR\" && rm -f \"$ZIP_PATH\" && ditto -c -k --keepParent \"$APP_DIR\" \"$ZIP_PATH\""
    echo ""
    echo "📦 Release archive (pre-staple): $ZIP_PATH"
else
    echo "🔏 Signing (ad-hoc)..."
    codesign --force --deep --sign - --entitlements /tmp/ImHear.entitlements "$APP_DIR"

    echo ""
    echo "✅ Done! → $APP_DIR"
    echo "🚀 open $APP_DIR"
    echo "⚠️  First launch: Microphone + Accessibility permission required"
fi
