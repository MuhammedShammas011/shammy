# MacLink – Troubleshooting

## Connection problems

### "Connection refused" on LAN

1. Confirm MacLinkHost is running and shows "Listening" or "Connected"
2. Check the IP address matches the one shown in MacLinkHost (Local IP)
3. Verify macOS firewall allows MacLinkHost: System Settings → Network → Firewall → Options
4. Try disabling the firewall temporarily to rule it out
5. Confirm both devices are on the same Wi-Fi network (not guest vs main SSID)

### "Connection refused" over Tailscale

1. Open the Tailscale app on both Mac and iPhone — confirm both show "Connected"
2. Verify the Tailscale IP (100.x.x.x) shown in MacLinkHost matches what you entered in MacLinkClient
3. On the Mac, run: `tailscale ping <your-iphone-tailscale-name>` to verify the tunnel is up
4. Check Tailscale admin panel at https://login.tailscale.com/admin/machines — both devices should appear
5. If using MagicDNS hostname, verify it resolves: `nslookup macbook-name.tailnet.ts.net`

### "Authentication failed. Check the shared secret."

1. Copy the secret directly from the MacLinkHost "Authentication" card using the Copy button
2. Paste it into MacLinkClient — do not retype manually
3. If the secret has changed (Generate New Secret was clicked), you must re-enter it on the iPhone
4. The secret is case-sensitive hex; make sure no trailing spaces were copied

### Reconnection loop

If MacLinkClient keeps reconnecting after a network change:
- The client will retry up to 5 times with increasing delay
- After 5 failures it stops and shows an error
- Tap **Connect** to start fresh

---

## Screen capture problems

### "Screen Recording permission required"

1. Open System Settings → Privacy & Security → Screen Recording
2. Find MacLinkHost and enable it (toggle to on)
3. **Quit and relaunch MacLinkHost** — the permission is cached at launch time
4. If MacLinkHost does not appear in the list, run it once so macOS registers it, then check again

### Black / blank screen on iPhone

Possible causes:
1. **Mac display is off or screen saver active** — move the mouse on the Mac to wake it
2. **Stream has stalled** — disconnect and reconnect
3. **Mac lid is closed** — a clamshell Mac with no external monitor cannot be captured
4. **ScreenCaptureKit was interrupted** — grant permission again and restart the session

### Very low FPS (< 5 fps)

1. Check CPU usage on the Mac (Activity Monitor) — JPEG encoding is CPU-heavy
2. Switch to H.264 mode: in `VideoStreamer.swift`, set `mode = .h264` and rebuild
3. Reduce the quality: in MacLinkClient, future versions will expose a quality slider
4. Check network bandwidth: on Tailscale, run `tailscale netcheck` and look for latency

---

## Input control problems

### Mouse clicks / keyboard have no effect

1. Check "Accessibility" shows ✓ in MacLinkHost — grant it if not
2. After granting Accessibility, restart MacLinkHost
3. Verify that the session is "Connected" (not just "Listening")
4. Test with a simple app like TextEdit first — some apps (e.g., system dialogs) block injected events

### Mouse moves to wrong location

The coordinate mapping depends on the display resolution reported at session start.
If you changed your display resolution or connected an external monitor after starting the session:
1. Disconnect from MacLinkClient
2. Reconnect — the host re-reads the display info at session start

### Keyboard shortcuts not working

- Check that the correct modifier is toggled (sticky): tap ⌘, then tap the key
- Command+Space requires Spotlight to be enabled; some launchers intercept it
- Command+Tab works for app switching only when no app is in full-screen focus

---

## Sleep and wake

### Can I wake a sleeping Mac?

Not directly. MacLink requires the Mac to be awake and the screen to be on (or an external display connected in clamshell mode).

**Options:**
- Enable **Power Nap** (System Settings → Battery → Power Adapter → Enable Power Nap) — the Mac can receive network connections while sleeping
- Enable **Wake for network access** in Battery settings — some Macs support Wake-on-LAN
- Use a scheduled wake: `sudo pmset repeat wake MTWRFSU 07:00:00`

### Mac screen went to sleep during a session

The screen may turn off, but the Mac stays awake. ScreenCaptureKit typically continues to capture a black/sleep-screen frame. To recover:
1. Press a key on the Mac keyboard to wake the display
2. If the stream does not resume, disconnect and reconnect from the iPhone

---

## Performance tips

| Action | Expected improvement |
|--------|---------------------|
| Switch from JPEG to H.264 mode | 50-70% reduction in bandwidth |
| Reduce target FPS to 15 | Halves CPU/bandwidth with acceptable smoothness |
| Use 1280×720 instead of native | Reduces encode work on Retina displays |
| Connect on same Wi-Fi (not cellular) | Lowest latency path |
| Use Tailscale direct connection (not DERP) | Check with `tailscale netcheck` |

---

## Reporting issues

This is a personal project. Keep an implementation log in:
`MacLink/docs/implementation-log.md` tracking:
- Date and macOS/iOS version
- What was tested
- What worked, what did not
- Any error messages
