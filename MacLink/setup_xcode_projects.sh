#!/bin/bash
# setup_xcode_projects.sh
# MacLink – One-time Xcode project setup helper
# Usage: bash setup_xcode_projects.sh
# Run from the MacLink root directory after installing Xcode.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$SCRIPT_DIR/macos/MacLinkHost"
IOS_DIR="$SCRIPT_DIR/ios/MacLinkClient"

echo "=================================================="
echo "  MacLink – Xcode Project Setup"
echo "=================================================="
echo ""
echo "This script will guide you through creating the two"
echo "Xcode projects needed to build MacLink."
echo ""

# Check Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode is not installed or xcode-select path is wrong."
    echo "   Install Xcode from the App Store, then run:"
    echo "   sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version | head -1)
echo "✅ Found: $XCODE_VERSION"
echo ""

# ---------------------------------------------------------------
# macOS Host project
# ---------------------------------------------------------------
echo "── macOS Host Project ──────────────────────────────"
echo ""
echo "Steps to create the macOS host Xcode project:"
echo ""
echo "  1. Open Xcode → File → New → Project"
echo "  2. Choose: macOS → App"
echo "  3. Fill in:"
echo "     Product Name:       MacLinkHost"
echo "     Team:               (your Apple ID / Personal Team)"
echo "     Organization ID:    com.yourname   (any reverse-domain)"
echo "     Bundle ID:          com.yourname.MacLinkHost"
echo "     Interface:          SwiftUI"
echo "     Language:           Swift"
echo "  4. Save location: $MACOS_DIR"
echo "     (Click the folder icon and navigate there)"
echo ""
echo "  5. After creating, in Xcode:"
echo "     - Delete ContentView.swift (move to Trash)"
echo "     - File → Add Files to 'MacLinkHost'…"
echo "       Add all .swift files from:"
echo "       • $MACOS_DIR/App/"
echo "       • $MACOS_DIR/Capture/"
echo "       • $MACOS_DIR/Input/"
echo "       • $MACOS_DIR/Networking/"
echo "       • $MACOS_DIR/UI/"
echo "       • $SCRIPT_DIR/shared/Protocol/"
echo ""
echo "  6. Target settings:"
echo "     - Minimum Deployment: macOS 13.0"
echo "     - Signing & Capabilities → disable App Sandbox (for dev)"
echo ""
echo "  7. Info.plist — add key:"
echo "     NSScreenCaptureUsageDescription"
echo "     Value: MacLink needs screen recording to stream your desktop."
echo ""

# ---------------------------------------------------------------
# iOS Client project
# ---------------------------------------------------------------
echo "── iOS Client Project ──────────────────────────────"
echo ""
echo "Steps to create the iOS client Xcode project:"
echo ""
echo "  1. Open Xcode → File → New → Project"
echo "  2. Choose: iOS → App"
echo "  3. Fill in:"
echo "     Product Name:       MacLinkClient"
echo "     Team:               (your Apple ID / Personal Team)"
echo "     Organization ID:    com.yourname"
echo "     Bundle ID:          com.yourname.MacLinkClient"
echo "     Interface:          SwiftUI"
echo "     Language:           Swift"
echo "  4. Save location: $IOS_DIR"
echo ""
echo "  5. After creating, in Xcode:"
echo "     - Delete ContentView.swift"
echo "     - File → Add Files to 'MacLinkClient'…"
echo "       Add all .swift files from:"
echo "       • $IOS_DIR/App/"
echo "       • $IOS_DIR/RemoteDesktop/"
echo "       • $IOS_DIR/Input/"
echo "       • $IOS_DIR/UI/"
echo "       • $SCRIPT_DIR/shared/Protocol/"
echo ""
echo "  6. Target settings:"
echo "     - Minimum Deployment: iOS 16.0"
echo "     - Supported Destinations: iPhone"
echo ""
echo "  7. Info.plist — add key:"
echo "     NSLocalNetworkUsageDescription"
echo "     Value: MacLink connects to your Mac on the local network."
echo ""

# ---------------------------------------------------------------
# Build verification
# ---------------------------------------------------------------
echo "── Build Verification ──────────────────────────────"
echo ""
echo "After setting up both projects, build from the command line:"
echo ""
echo "  # macOS host"
echo "  xcodebuild -project $MACOS_DIR/MacLinkHost.xcodeproj \\"
echo "             -scheme MacLinkHost -configuration Debug build"
echo ""
echo "  # iOS client (simulator)"
echo "  xcodebuild -project $IOS_DIR/MacLinkClient.xcodeproj \\"
echo "             -scheme MacLinkClient \\"
echo "             -destination 'platform=iOS Simulator,name=iPhone 15' build"
echo ""
echo "=================================================="
echo "  Done! See README.md for first-run instructions."
echo "=================================================="
