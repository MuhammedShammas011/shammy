# MacLink – Networking Guide

## Overview

MacLink uses a single TCP connection between the iPhone client and the Mac host.
Video frames and control messages share the same socket, eliminating the need for
a separate video UDP channel in the baseline implementation.

```
iPhone  ──── TCP (port 55100) ──── MacBook
          Control messages (JSON)
          Video frames (JPEG or H.264 Annex-B)
          Both multiplexed on same stream
```

---

## Protocol wire format

Every message is prefixed with a 4-byte big-endian length field:

```
┌─────────────────────────────────────┐
│  4 bytes: payload length (big-endian) │
│  N bytes: JSON control message        │
└─────────────────────────────────────┘
```

Video frames use a different prefix byte (0x01 = JPEG, 0x02 = H.264) so the receiver can
distinguish them from JSON control messages without ambiguity.

---

## Connection sequence

```
iPhone                           MacBook
  │                                 │
  │──── TCP connect (port 55100) ──→│
  │                                 │
  │──── HELLO ─────────────────────→│  device name, platform
  │←─── HELLO ACK ─────────────────│  macOS version, display count
  │←─── AUTH CHALLENGE ────────────│  random 32-byte hex token
  │──── AUTH RESPONSE ─────────────→│  HMAC-SHA256(secret, challenge)
  │←─── AUTH RESULT ───────────────│  success/failure
  │←─── SESSION STARTED ───────────│  display dimensions, session ID
  │                                 │
  │←════ VIDEO FRAMES (continuous) ═│  JPEG or H.264 Annex-B
  │────→ MOUSE / KEY EVENTS ────────│  normalised coordinates
  │←────→ PING / PONG ─────────────│  latency measurement (every 5s)
```

Authentication uses HMAC-SHA256 with the shared secret stored in UserDefaults on the Mac.
The secret is displayed in the MacLinkHost app and must be entered once in the iPhone app.
It is persisted in the iPhone's UserDefaults for future sessions.

---

## Same-network (LAN) connectivity

- The Mac binds a TCP listener on all interfaces (port 55100)
- The iPhone connects using the Mac's en0 IP address
- No router configuration required
- The Mac's firewall must allow incoming connections on port 55100

**macOS firewall:** System Settings → Network → Firewall → Options → Add MacLinkHost

---

## Cross-network (Tailscale) connectivity

### Why Tailscale?

Tailscale creates a private WireGuard mesh network between your devices.
Key properties relevant to MacLink:
- Works without opening ports on your home router
- Works when the iPhone is on cellular and the Mac is on home Wi-Fi
- Works with CGNAT (carrier-grade NAT) on cellular networks
- Uses peer-to-peer direct connections (DERP relay only as fallback)
- Latency overhead: typically 5–15 ms on direct connections

### Setup

1. **Mac:** Install Tailscale from https://tailscale.com/download/mac
2. **iPhone:** Install Tailscale from the App Store
3. Log in to the same Tailscale account on both devices
4. On the Mac: open MacLinkHost — the Tailscale IP (100.x.x.x) will appear automatically
5. On the iPhone: enter the Tailscale IP in MacLinkClient

### MagicDNS

If MagicDNS is enabled in your Tailscale admin panel, you can use a hostname instead of the IP:
- Format: `macbook-name.tailnet-name.ts.net`
- Example: `shammass-macbook-pro.tail12345.ts.net`

### Verifying the Tailscale connection

```bash
# On Mac — check Tailscale is up and get your IP
tailscale status
tailscale ip -4

# Ping the Mac from iPhone (open Tailscale app → device → Test connection)
```

---

## Port configuration

| Port  | Protocol | Purpose |
|-------|----------|---------|
| 55100 | TCP      | Control messages + video frames (default) |

To change the port, edit `MacLinkConstants.defaultControlPort` in `MacLinkProtocol.swift`
and restart both apps.

---

## Firewall considerations

### macOS Application Firewall

If enabled, macOS will prompt to allow/deny incoming connections when MacLinkHost first starts.
Click **Allow**. If you clicked Deny:
1. System Settings → Network → Firewall → Options
2. Find MacLinkHost, change to "Allow incoming connections"

### macOS pf / Little Snitch

If you use a packet filter, allow TCP on port 55100 incoming on the Tailscale or en0 interface.

---

## NAT traversal

MacLink does **not** implement NAT traversal.  
For cross-network use, Tailscale handles all NAT traversal transparently using WireGuard + DERP.  
Do not expose MacLinkHost's TCP port directly to the public internet.

---

## Connection diagnostics

The MacLinkHost app displays:
- Local IP (en0 or primary interface)
- Tailscale IP (100.x.x.x, if Tailscale is running)
- Control port

The MacLinkClient app displays:
- Connection state
- Ping latency (ms) — updated every 5 seconds
- Live frame rate (fps)

Use these to diagnose:
- **latency > 200 ms:** check Tailscale route (may be using DERP relay instead of direct)
- **fps = 0 but latency ok:** screen capture may have been interrupted; disconnect and reconnect
- **connection refused:** check macOS firewall, verify Tailscale is connected on both devices
