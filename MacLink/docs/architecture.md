# MacLink – Architecture

## Design Principles

- **Minimal dependencies** — no Node.js, no cloud backend, no external signalling server
- **Single TCP connection** — control and video share one socket; no NAT traversal required beyond Tailscale
- **Incremental milestones** — each milestone produces a runnable end-to-end system
- **Native APIs** — ScreenCaptureKit, VideoToolbox, CGEvent, Network.framework, SwiftUI

---

## Component diagram

```
┌───────────────────────────────────────────────────────────┐
│                      MacBook                               │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │                  MacLinkHost (macOS app)               │ │
│  │                                                      │ │
│  │  ┌─────────────────┐   CMSampleBuffer                │ │
│  │  │ScreenCaptureKit │──────────────────────┐          │ │
│  │  │   (display)     │                      ▼          │ │
│  │  └─────────────────┘              ┌───────────────┐  │ │
│  │                                   │  VideoStreamer │  │ │
│  │  ┌─────────────────┐              │  JPEG / H.264 │  │ │
│  │  │  SessionManager │◄────────────►│  VideoToolbox │  │ │
│  │  │  (coordinator)  │              └───────┬───────┘  │ │
│  │  └────────┬────────┘                      │          │ │
│  │           │                               │ frames   │ │
│  │           │ control msgs                  │          │ │
│  │  ┌────────▼────────┐              ┌───────▼───────┐  │ │
│  │  │  ControlServer  │◄────────────►│  TCP Socket   │  │ │
│  │  │  (NWListener)   │  JSON msgs   │  (same conn)  │  │ │
│  │  └────────┬────────┘              └───────────────┘  │ │
│  │           │ mouse/key payloads                        │ │
│  │  ┌────────▼────────┐                                  │ │
│  │  │  InputInjector  │                                  │ │
│  │  │   (CGEvent)     │                                  │ │
│  │  └─────────────────┘                                  │ │
│  └──────────────────────────────────────────────────────┘ │
└──────────────────────────┬────────────────────────────────┘
                           │ TCP port 55100
                           │ (LAN or Tailscale VPN)
┌──────────────────────────▼────────────────────────────────┐
│                      iPhone                                │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │                  MacLinkClient (iOS app)              │ │
│  │                                                      │ │
│  │  ┌─────────────────┐   UIImage frames                │ │
│  │  │  ClientSession  │──────────────────────┐          │ │
│  │  │  (NWConnection) │                      ▼          │ │
│  │  └────────┬────────┘              ┌───────────────┐  │ │
│  │           │ ControlMessages       │RemoteDesktop  │  │ │
│  │           │                       │   View        │  │ │
│  │  ┌────────▼────────┐              │ (UIKit gestures│ │ │
│  │  │  KeyboardView   │              │  → norm coords)│ │ │
│  │  │ (special keys,  │              └───────────────┘  │ │
│  │  │  modifiers,     │                                  │ │
│  │  │  shortcuts)     │                                  │ │
│  │  └─────────────────┘                                  │ │
│  └──────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

---

## Data flow: screen frame

```
ScreenCaptureKit (60fps hardware capture)
  → CMSampleBuffer (CVPixelBuffer, BGRA)
  → VideoStreamer.enqueue()
    [JPEG path]
      → CIImage → CGImage → NSBitmapImageRep → JPEG data
      → 1-byte type + 8-byte index + 4-byte length + JPEG
      → NWConnection.send()
    [H.264 path]
      → VTCompressionSession (H.264 Baseline, real-time)
      → NAL units → Annex-B framing (SPS+PPS prepended on keyframes)
      → 1-byte type + 8-byte index + 4-byte length + Annex-B
      → NWConnection.send()

  [iPhone receives]
  → drainBuffer() detects frame packet (first byte 0x01 / 0x02)
  → UIImage(data:) for JPEG
  → VideoDecoder (H.264, future)
  → framePublisher.send(image)
  → RemoteDesktopView updates DesktopUIView.image
```

## Data flow: control message

```
iPhone gesture recogniser
  → DesktopView.Coordinator.handleTap/Pan/TwoFingerPan
  → DesktopUIView.normalise() → normX, normY ∈ [0,1]
  → ControlMessage(type: .mouseMove, payload: ...)
  → MessageFramer.encode() → 4-byte length + JSON
  → NWConnection.send()

  [Mac receives]
  → ControlServer.startReceiving()
  → MessageFramer.decode()
  → SessionManager.handleControlMessage()
  → InputInjector.injectMouseMove()
  → CGEvent(mouseEventSource:, mouseType:, mouseCursorPosition:)
  → event.post(tap: .cghidEventTap)
```

---

## Authentication

MacLink uses a simple HMAC-SHA256 challenge-response scheme:

1. Mac generates a random 32-byte challenge hex string
2. iPhone computes: `HMAC-SHA256(sharedSecret, challenge)` and sends the hex result
3. Mac independently computes the same HMAC and compares (constant-time comparison via CryptoKit)
4. The shared secret is generated randomly on first launch and stored in UserDefaults on the Mac

This is sufficient for a personal-use tool on a private network. The Tailscale layer provides
transport-level encryption (WireGuard), so the application-level auth primarily prevents
accidental connections from other devices on the same Tailscale network.

---

## Coordinate system

The Mac display uses a Cartesian coordinate system with the origin at the **top-left**.
CGEvent expects absolute pixel coordinates in this space.

Normalised coordinates (`normX`, `normY`) ∈ [0, 1] are used on the wire:
- `(0, 0)` = top-left of the captured display
- `(1, 1)` = bottom-right

On the iPhone, `DesktopUIView.normalise()` converts touch points to normalised coordinates,
correctly accounting for aspect-fit letterboxing.

On the Mac, `InputInjector.toScreenPoint()` converts back to pixels:
```
x = normX × displayWidth
y = normY × displayHeight
```

This means the coordinate mapping is always accurate regardless of the stream resolution,
device screen size, or orientation.

---

## Threading model

| Thread | Purpose |
|--------|---------|
| Main actor | All `@Published` state, SwiftUI updates |
| `maclink.capture` | ScreenCaptureKit frame callbacks, JPEG encoding |
| `maclink.encode`  | VideoToolbox H.264 encoding |
| `maclink.server`  | NWListener + NWConnection callbacks |
| `maclink.client`  | NWConnection callbacks (iOS) |

All UI updates cross back to the main actor via `Task { @MainActor in ... }`.

---

## Future work

| Item | Notes |
|------|-------|
| H.264 hardware decode on iPhone | Use `VideoToolbox` decompress session or `AVSampleBufferDisplayLayer` |
| Multi-display selection | Enumerate `SCShareableContent.displays`, let user pick |
| Audio streaming | Add `AVAudioEngine` on Mac, `AVAudioPlayer` on iPhone |
| Dynamic bitrate control | Measure RTT from ping; adjust VideoStreamer quality |
| Cursor shape sync | Not available via ScreenCaptureKit; show touch indicator instead |
| mDNS discovery | Advertise service via `NWListener` with `NWParameters.applicationService` |
