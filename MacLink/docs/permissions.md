# MacLink – Permissions Guide

## Required permissions

MacLink Host requires two macOS privacy permissions to work.

---

## 1. Screen Recording

**Why:** ScreenCaptureKit (Apple's modern screen capture API) requires the app to be listed in
the Screen Recording privacy group. Without this, no display content can be captured.

**How to grant:**
1. Open **System Settings** (macOS 13+) or **System Preferences** (macOS 12)
2. Go to **Privacy & Security → Screen Recording**
3. Find **MacLinkHost** in the list and toggle it on
4. Quit and relaunch MacLinkHost

Or click **Grant Access** in the MacLinkHost permission card — the app will open the correct pane.

**Verification:** The MacLinkHost main window shows a green ✓ next to "Screen Recording" when permission is granted. If the indicator stays orange after granting, quit and reopen the app.

---

## 2. Accessibility (Input Control)

**Why:** Injecting mouse and keyboard events via CoreGraphics (`CGEvent.post`) requires the app
to be trusted in the Accessibility privacy group. Without this, mouse and keyboard commands from
the iPhone will be silently ignored.

**How to grant:**
1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button and add MacLinkHost
3. Or toggle the existing entry if it appears but is disabled

macOS will show a dialog the first time the app attempts to use `AXIsProcessTrustedWithOptions`.
Click **Open System Preferences** in that dialog to navigate directly.

**Note:** Changes to Accessibility take effect immediately — no restart required.

---

## 3. App Sandbox (development builds)

If you are running a development (non-sandboxed) build, no additional entitlements are required.

For a sandboxed build (App Store distribution), add these entitlements to the `.entitlements` file:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.screen-capture</key>
<true/>
<!-- Outgoing network connections for the TCP server -->
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

---

## 4. Local Network (iOS)

On iOS, `NWConnection` targeting a local network address triggers the Local Network permission
dialog automatically the first time you connect on a LAN address. The permission appears once;
if denied, go to **Settings → Privacy & Security → Local Network** and re-enable MacLinkClient.

For Tailscale addresses (100.x.x.x), the traffic goes through the Tailscale VPN tunnel and does
not require a separate local network permission.

---

## Permission failure scenarios

| Failure | Symptom | Fix |
|---------|---------|-----|
| Screen Recording denied | "Screen capture failed" error | Grant in System Settings, relaunch |
| Accessibility denied | Mouse/keyboard events ignored | Grant in System Settings |
| iOS Local Network denied | Connection refused on LAN | Enable in iOS Settings |
| Tailscale not running | Cannot reach 100.x.x.x | Open Tailscale app, connect |
| App Sandbox blocks socket | "Failed to start control server" | Add network entitlements or disable sandbox |
