# TouchBridge

A personal, user-space touchscreen driver for the ARZOPA portable monitor (ILITEK touch panel, USB `0x222A:0x0001`) on this MacBook Pro (macOS 15).

It takes exclusive control of the panel and sends each touch to the ARZOPA display, where you touched. The cursor stays on the MacBook screen unless a gesture needs the Warp path. No kernel or system extension is involved, it doesn't run as root, and SIP is untouched. Quitting it gives the panel back to macOS.

Design and decisions are in `docs/spec.md` (the approved plan, plus implementation notes). Future work is in `docs/backlog.md`.

## Build and run

```bash
./scripts/bundle.sh                 # swift build + build/TouchBridge.app, signed with "TouchBridge Dev"
open -n build/TouchBridge.app       # menu-bar agent (✋ icon)
swift test                          # TouchCore unit tests + replays of real panel recordings
```

The app needs **Accessibility** permission (System Settings → Privacy & Security). The stable self-signed certificate keeps that permission across rebuilds.

## Gestures

| Touch | Result |
|---|---|
| Tap / double-tap / triple-tap | Left click (click count 1/2/3) |
| Hold about 0.5 s, then lift | Right-click |
| One-finger drag | **Scroll** with momentum (default); click-and-drag when "One-Finger Drag Scrolls" is off |
| Hold, then drag | Click-and-drag (select text, move files) |
| Drag starting on a toolbar, title bar or title text | Move the window (Chromium/Electron apps: top 28 pt) |
| Two fingers moving together | Scroll with momentum |
| Two fingers apart/together | Pinch to zoom |
| Two fingers around each other | Rotate |
| More than 3 fingers | Ignored (palm). All 10 fingers are still tracked; see "Touches" in the menu |

## Delivery

- **Direct (default):** events are posted straight to the app under the finger, so the cursor never moves.
  - A tap, drag or pinch activates that app first, because macOS ignores clicks aimed at a background window.
  - "Return Focus to Previous App" re-activates your MacBook app about 0.6 s afterwards.
- **Warp:** the cursor is hidden, jumps to the finger, and returns about 50 ms later. Used for window moves, hold-drags, the Dock and menu bar, popup menus, Chromium/Electron apps, and the desktop.

## Menu (✋)

The menu has:
- status lines: panel, display, last gesture, touches;
- Enabled;
- Delivery: Automatic, Direct only (testing), Warp only (testing);
- Pinch & Rotate Direct;
- One-Finger Drag Scrolls;
- Return Focus to Previous App;
- Dry Run (log only);
- Open Event Sink, Open Logs Folder, Quit.

## Logs and diagnostics

All logs are in `~/Library/Logs/TouchBridge/`:

- `touchbridge.log`: every gesture and how it was routed.
- `eventsink.log`: what the Event Sink test window received.
- `open -n build/TouchBridge.app --args --probe 90`: records raw panel reports (`probe-*.jsonl`).
- `open -n build/TouchBridge.app --args --dry-run`: recognizes touches and logs them without posting anything.
- `open -g -n build/TouchBridge.app --args --direct-selftest`: posts test events to the Event Sink only.
- `open -g -n build/TouchBridge.app --args --ax-probe --map`: read-only map of the window-drag areas on screen.
- `open -g -n build/TouchBridge.app --args --restart-selftest`: starts, stops and restarts the panel input (regression check for "Disable → Enable").

## Rolling back

Restore points are full copies in `~/Projects/TouchBridge-restore-<date>/`, including a runnable `TouchBridge-known-good.app`. To go back, quit TouchBridge from the menu, then:

```bash
open -n ~/Projects/TouchBridge-restore-20261009-2214/TouchBridge-known-good.app
```

To return to macOS's default touch behaviour, quit TouchBridge. To re-enable the old Touchscreen Gestures app, run these two commands for each of its labels (`com.touchscreen.gestures` and `com.touchscreen.gestures.maintenance`):

```bash
launchctl enable gui/501/com.touchscreen.gestures
```

```bash
launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.touchscreen.gestures.plist
```
