# MacLink

**Personal remote desktop application — control your MacBook from your iPhone over any network.**

MacLink streams your Mac's live desktop to your iPhone and lets you control it with touch gestures, a trackpad-style surface, and an on-screen keyboard — including modifier keys and developer shortcuts.

---

## Architecture

```
MacBook (macOS 13+)
  └── MacLinkHost (SwiftUI app)
        ├── ScreenCaptureKit  → live display frames
        ├── VideoToolbox      → H.264 / JPEG encoding
        ├── NWListener (TCP)  → control & video socket
        └── CGEvent           → mouse / keyboard injection

iPhone (iOS 16+)
  └── MacLinkClient (SwiftUI app)
        ├── NWConnection (TCP) → connects to Mac host
        ├── JPEG / H.264 decoder → UIImage frames
        ├── UIGestureRecognizer → touch → mouse events
        └── KeyboardView        → key / text events

Network path
  LAN: en0 / Wi-Fi (same network)
  WAN: Tailscale VPN (any network, no port forwarding needed)

Protocol
  Single TCP connection (port 55100 default)
  Length-prefixed JSON control messages
  Video frames multiplexed on same connection
  HMAC-SHA256 shared-secret authentication
```

---

## Requirements

| Component | Minimum version |
|-----------|----------------|
| macOS     | 13.0 Ventura   |
| iOS       | 16.0           |
| Xcode     | 15.0           |
| Swift     | 5.9            |

---

## Getting Started

### 1. Install Xcode

Download from the Mac App Store: https://apps.apple.com/app/xcode/id497799835

### 2. Open the projects

MacLink uses two separate Xcode projects (one per platform):

```
MacLink/
├── macos/MacLinkHost/MacLinkHost.xcodeproj   ← open on Mac
└── ios/MacLinkClient/MacLinkClient.xcodeproj  ← open on Mac, run on iPhone
```

See [Setting Up Xcode Projects](#setting-up-xcode-projects) below.

### 3. Grant permissions on macOS

Before the host app can capture or control the screen:

- **System Settings → Privacy & Security → Screen Recording** — add MacLinkHost
- **System Settings → Privacy & Security → Accessibility** — add MacLinkHost

The app's permission screen will guide you through this.

### 4. Configure networking

**Same network (LAN):**
- Use the Local IP shown in the Mac app (e.g. `192.168.1.42:55100`)

**Different networks (cellular / different Wi-Fi):**
- Install [Tailscale](https://tailscale.com) on both Mac and iPhone
- Log in with the same account
- Use the Tailscale IP (e.g. `100.x.x.x:55100`) shown in the Mac app

### 5. Connect

1. Open **MacLinkHost** on your Mac and press **Start Session**
2. Copy the **Connection Address** and **Shared Secret**
3. Open **MacLinkClient** on your iPhone
4. Paste the address and secret, then tap **Connect**

---

## Setting Up Xcode Projects

Because SwiftUI + ScreenCaptureKit apps require native Xcode targets (not just SPM executables), you need to create two Xcode projects manually. This is a one-time step.

### macOS host

1. In Xcode: File → New → Project → macOS → App
2. Product Name: `MacLinkHost`
3. Interface: SwiftUI, Language: Swift
4. Save inside `MacLink/macos/MacLinkHost/`
5. Delete the generated `ContentView.swift`
6. Add all `.swift` files from `macos/MacLinkHost/` to the target
7. Add the files from `shared/Protocol/` to the target
8. In the target's **Signing & Capabilities**, add:
   - `com.apple.security.device.camera` — not needed, but ScreenCaptureKit requires the entitlement below
   - Add `com.apple.security.app-sandbox` and within it enable **Screen Capture**
   - Or disable App Sandbox for personal local use (simpler for development)
9. In **Info.plist**, add `NSScreenCaptureUsageDescription`

### iOS client

1. In Xcode: File → New → Project → iOS → App
2. Product Name: `MacLinkClient`
3. Interface: SwiftUI, Language: Swift
4. Save inside `MacLink/ios/MacLinkClient/`
5. Delete the generated `ContentView.swift`
6. Add all `.swift` files from `ios/MacLinkClient/` to the target
7. Add the files from `shared/Protocol/` to the target
8. In **Info.plist**, add `NSLocalNetworkUsageDescription` and a Bonjour service type if using mDNS

---

## Building & Running

```bash
# Build macOS host from command line (requires Xcode installed)
xcodebuild -project macos/MacLinkHost/MacLinkHost.xcodeproj \
           -scheme MacLinkHost \
           -configuration Debug \
           build

# Build iOS client for simulator
xcodebuild -project ios/MacLinkClient/MacLinkClient.xcodeproj \
           -scheme MacLinkClient \
           -destination 'platform=iOS Simulator,name=iPhone 15' \
           build
```

For device deployment, open the project in Xcode and use the Run button.

---

## Features

| Feature | Status |
|---------|--------|
| Live screen capture (ScreenCaptureKit) | ✅ |
| JPEG streaming over TCP | ✅ |
| H.264/VideoToolbox streaming | ✅ (enable in VideoStreamer.mode) |
| HMAC-SHA256 authentication | ✅ |
| Mouse movement, click, drag | ✅ |
| Right-click (long press) | ✅ |
| Two-finger scroll | ✅ |
| Trackpad / direct touch / scroll modes | ✅ |
| Text input | ✅ |
| Special keys (Esc, Tab, arrows, etc.) | ✅ |
| Modifier keys (⌘ ⌥ ⌃ ⇧) | ✅ |
| Common shortcuts (⌘C, ⌘V, ⌘Tab…) | ✅ |
| Automatic reconnection | ✅ |
| Ping latency measurement | ✅ |
| Tailscale cross-network | ✅ |
| Configurable FPS / resolution | ✅ |

---

## Known Limitations

- **Mac must be awake.** A sleeping Mac or a MacBook with a closed lid (clamshell) cannot be woken remotely unless Wake-on-LAN or Power Nap is configured. See [docs/troubleshooting.md](docs/troubleshooting.md).
- **Accessibility permission required for input.** Without it, mouse and keyboard injection is blocked by macOS. The UI shows a clear message and links to System Settings.
- **No support for protected UI elements.** CGEvent cannot inject keystrokes into password fields in some applications (e.g. 1Password) — this is a macOS security restriction.
- **App Sandbox limitations.** If the sandbox is enabled, additional entitlements are needed. For personal development use, disabling the sandbox is the simplest path.
- **Single display.** Only the main display is captured. Multi-monitor support is a future milestone.
- **No audio.** Audio streaming is not implemented.

---

## Milestones

- [x] Milestone 1: Local screen capture
- [x] Milestone 2: iPhone screen preview (JPEG over TCP)
- [x] Milestone 3: Remote mouse control
- [x] Milestone 4: Keyboard control
- [ ] Milestone 5: H.264 hardware encoding end-to-end (enable in VideoStreamer.mode = .h264)
- [ ] Milestone 6: Performance tuning & sleep/wake recovery
- [ ] Milestone 7: Final documentation pass

---

## Project Structure

```
MacLink/
├── README.md
├── Package.swift
├── docs/
│   ├── architecture.md
│   ├── networking.md
│   ├── permissions.md
│   └── troubleshooting.md
├── shared/
│   └── Protocol/
│       └── MacLinkProtocol.swift       ← wire format, message types, framing
├── macos/
│   └── MacLinkHost/
│       ├── App/
│       │   ├── MacLinkHostApp.swift    ← app entry + AppDelegate
│       │   ├── SessionManager.swift    ← central coordinator
│       │   └── PermissionChecker.swift
│       ├── Capture/
│       │   ├── ScreenCaptureManager.swift  ← ScreenCaptureKit
│       │   └── VideoStreamer.swift          ← JPEG + H.264 encoding
│       ├── Input/
│       │   └── InputInjector.swift     ← CGEvent mouse & keyboard
│       ├── Networking/
│       │   ├── ControlServer.swift     ← TCP server + auth
│       │   └── NetworkUtils.swift      ← IP discovery
│       └── UI/
│           └── ContentView.swift       ← macOS SwiftUI UI
├── ios/
│   └── MacLinkClient/
│       ├── App/
│       │   ├── MacLinkClientApp.swift  ← app entry
│       │   └── ClientSession.swift     ← connection + video receive
│       ├── RemoteDesktop/
│       │   └── RemoteDesktopView.swift ← live viewer + gesture bridge
│       ├── Input/
│       │   └── KeyboardView.swift      ← on-screen keyboard
│       ├── Networking/
│       │   └── (reuses NetworkUtils from shared)
│       └── UI/
│           ├── RootView.swift          ← connect / desktop navigation
│           └── ConnectView.swift       ← setup form
└── tests/
    └── (protocol framing unit tests — add with XCTest)
```
