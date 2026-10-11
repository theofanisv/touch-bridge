# TouchBridge

A personal, user-space touchscreen driver for the ARZOPA portable monitor (ILITEK touch panel, USB `0x222A:0x0001`) on this MacBook Pro (macOS 15).

It takes exclusive control of the panel and sends each touch to the ARZOPA display, where you touched. The cursor stays on the MacBook screen unless a gesture needs the Warp path. No kernel or system extension is involved, it doesn't run as root, and SIP is untouched. Quitting it gives the panel back to macOS.

Design and decisions are in `docs/spec.md` (the approved plan, plus implementation notes). Future work is in `docs/backlog.md`.

## Build, install and run

```bash
./scripts/install.sh                # build + install to ~/Applications/TouchBridge.app (the daily copy) + (re)start it
./scripts/bundle.sh                 # build only: build/TouchBridge.app, signed with "TouchBridge Dev" (for development)
swift test                          # unit tests, deliverer tests, replays of real panel recordings
```

- **The installed copy runs as a login item** (menu: Start at Login): a per-user launch agent, `~/Library/LaunchAgents/com.theofanis.touchbridge.agent.plist`, that runs `~/Applications/TouchBridge.app/Contents/MacOS/TouchBridge`.
  - It starts at login and is restarted within seconds after a crash.
  - Quit from the menu stays quit until the next login.
  - Start it again with `launchctl kickstart gui/$(id -u)/com.theofanis.touchbridge.agent`, or by opening the app.
  - It isn't an `SMAppService` login item: that API pins the exact build it registered, so every rebuild of this self-signed app broke it.
- **Rebuilding in the project folder** never touches the installed copy. Run `scripts/install.sh` to update it.

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
| Two fingers from the right edge, moving left | Notification Center |
| Three fingers moving together | Click-and-drag (grabs at the centre of the fingers, or under the first finger: menu "Three-Finger Drag Point") |
| One finger resting on an item, two more added within 1.5 s, then moving | Click-and-drag that grabs exactly where the resting finger first touched |
| Four fingers up / down | Mission Control / App Exposé |
| Four fingers left / right | Switch Space |
| Thumb and three or four fingers pinching / spreading | Launchpad / Show Desktop |
| Six or more fingers | Ignored (palm). All 10 fingers are still tracked; see "Touches" in the menu |

With "Follow Trackpad Settings" on (the default), each gesture follows its switch in System Settings → Trackpad, re-read every 3 s and after wake.

The four-finger gestures are the system's own animated ones: the fingers drive Mission Control, Spaces and Launchpad as on the trackpad.
- Space switching acts on the display with the cursor, so the hidden cursor waits on the touch display until the animation is under way. macOS then moves focus to the switched display. With "Keep Focus When Switching Spaces" on (the default), focus that was on the MacBook goes back to that app; touching the panel within 1.5 s leaves focus alone. Off: focus follows the switch.
- Notification Center opens on the touch display: it appears wherever the cursor is, so the menu-bar clock is pressed while the hidden cursor waits on the touch display (0.8 s).
- Launchpad opens on the display that has the Dock. A pinch-in on the touch display first brings the Dock there: the hidden cursor pushes against that display's bottom edge, as moving the Dock by hand does. Menu "Launchpad on the Touch Display":
  - Bring the Dock Over, Then Back (default): the Dock lives on the other display. After each Launchpad opened by touch, it returns once Launchpad has closed and no finger is on the panel. This happens even if it was already on the touch display. Choosing this item also sends a Dock found on the touch display home. With this mode, the trackpad keeps opening Launchpad on the MacBook.
  - Bring the Dock Over (it stays): the Dock then stays on the touch display, so the trackpad also opens Launchpad there.
  - Leave the Dock Where It Is: Launchpad opens wherever the Dock is.

After a power cycle (unplug, sleep) the panel starts in a single-touch "mouse" mode. TouchBridge switches it back to multitouch when it connects, and again if mouse-mode reports ever arrive. Both steps are logged.

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
- Follow Trackpad Settings, with the trackpad settings it read;
- Three-Finger Drag (greyed while following the trackpad), Three-Finger Drag Point;
- Launchpad on the Touch Display: Bring the Dock Over, Then Back (default), Bring the Dock Over (it stays), Leave the Dock Where It Is;
- Return Focus to Previous App;
- Keep Focus When Switching Spaces (default on);
- Dry Run (log only);
- Start at Login;
- Open Event Sink, Open Logs Folder, Quit.

## Logs and diagnostics

All logs are in `~/Library/Logs/TouchBridge/`:

- `touchbridge.log`: every gesture and how it was routed.
- `eventsink.log`: what the Event Sink test window received.
- `open -n build/TouchBridge.app --args --probe 90`: records raw panel reports (`probe-*.jsonl`).
- `open -n build/TouchBridge.app --args --dry-run`: recognizes touches and logs them without posting anything.
- `open -g -n build/TouchBridge.app --args --direct-selftest`: posts test events to the Event Sink only.
- `open -g -n build/TouchBridge.app --args --ax-probe --map`: read-only map of the window-drag areas on screen.
- `open -g -n build/TouchBridge.app --args --ax-probe --menubar`: read-only report of each display's menu bar and clock, the active menu-bar display and each display's current Space.
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
