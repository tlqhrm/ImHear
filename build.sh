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

echo "🔏 Signing..."
codesign --force --deep --sign - --entitlements /tmp/ImHear.entitlements "$APP_DIR"

echo ""
echo "✅ Done! → $APP_DIR"
echo ""
echo "🚀 open $APP_DIR"
echo ""
echo "⚠️  First launch: Microphone + Accessibility permission required"

# Create release zip if --release flag is passed
if [[ "$1" == "--release" ]]; then
    ZIP_PATH="$(pwd)/ImHear.zip"
    rm -f "$ZIP_PATH"
    cd "$HOME/Applications" && zip -r "$ZIP_PATH" ImHear.app
    echo ""
    echo "📦 Release archive: $ZIP_PATH"
fi
