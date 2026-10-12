#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "========================================"
echo "         Building Shammy App            "
echo "========================================"

APP_DIR="$DIR/build/Shammy.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [ ! -d "$SDK_PATH" ]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

echo "Using SDK: $SDK_PATH"
echo "Compiling Swift sources..."

swiftc -sdk "$SDK_PATH" \
    -parse-as-library \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -framework VideoToolbox \
    -framework CoreGraphics \
    -framework Network \
    -framework CryptoKit \
    -framework AppKit \
    shared/Protocol/MacLinkProtocol.swift \
    macos/MacLinkHost/App/*.swift \
    macos/MacLinkHost/Capture/*.swift \
    macos/MacLinkHost/Input/*.swift \
    macos/MacLinkHost/Networking/*.swift \
    macos/MacLinkHost/UI/*.swift \
    -o "$MACOS_DIR/Shammy"

echo "Copying icon and resources..."
if [ -f "$DIR/macos/MacLinkHost/Resources/AppIcon.icns" ]; then
    cp -f "$DIR/macos/MacLinkHost/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -f "$DIR/macos/MacLinkHost/Resources/AppIcon.png" ]; then
    cp -f "$DIR/macos/MacLinkHost/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
fi

echo "Creating Info.plist..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Shammy</string>
    <key>CFBundleIdentifier</key>
    <string>com.personal.Shammy</string>
    <key>CFBundleName</key>
    <string>Shammy</string>
    <key>CFBundleDisplayName</key>
    <string>Shammy</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Shammy needs screen recording permission to stream your desktop to your iPhone.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Shammy needs accessibility permission to control the mouse and keyboard.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Shammy needs access to the local network to stream your screen to your phone.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_shammy._tcp</string>
    </array>
</dict>
</plist>
EOF

echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "Signing application bundle with stable designated requirement..."
codesign --force --deep -s - -i "com.personal.Shammy" -r="designated => identifier \"com.personal.Shammy\"" "$APP_DIR"

echo "Build complete: $APP_DIR"

if [ "$1" == "--run" ] || [ "$1" == "-r" ] || [ -z "$1" ]; then
    echo "Stopping existing Shammy processes..."
    killall Shammy 2>/dev/null || true
    sleep 0.5
    echo "Launching Shammy in background..."
    open -n "$APP_DIR"
    sleep 1.5
    echo "Shammy is now running! (PID: $(pgrep Shammy | head -n 1))"
fi
