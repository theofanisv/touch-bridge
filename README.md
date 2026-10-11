# TouchBridge

**A real touchscreen for macOS, for USB touch monitors.** Touches act where you touch, the cursor stays where it is, and the trackpad's gestures work with your fingers on the screen: scrolling, pinch, rotate, Mission Control, Spaces, Launchpad, Notification Center and Safari's back/forward page swipes.

TouchBridge is a small menu-bar app that runs in user space:
- It takes over the touch panel and recognizes gestures itself.
- It sends macOS the same events a trackpad and mouse would, aimed at the window under your fingers.
- No kernel or system extension, no root, and System Integrity Protection stays on.
- Quitting it hands the panel back to macOS.

> **Hardware note:** TouchBridge was built for, and tested with, one touch monitor. The gesture engine is generic, but the input layer needs adapting for other panels. See [Hardware support](#hardware-support).

## Contents

- [Why](#why)
- [Features](#features)
- [Gestures](#gestures)
- [Drawing and multitouch apps](#drawing-and-multitouch-apps)
- [Hardware support](#hardware-support)
- [Requirements](#requirements)
- [Install](#install)
- [The menu](#the-menu)
- [How it works](#how-it-works)
- [Adapting to another touchscreen](#adapting-to-another-touchscreen)
- [Logs and diagnostics](#logs-and-diagnostics)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Development](#development)
- [Caveats](#caveats)
- [Credits](#credits)
- [License](#license)

## Why

macOS has no touchscreen support:
- **Touches land on the wrong screen.** macOS treats a USB touch panel as an absolute pointing device, mapped onto whichever display the cursor is on. With a touch monitor as a second display, touching it while the cursor is on the laptop clicks the matching spot on the laptop screen.
- **One finger at a time.** There's no multitouch: no two-finger scrolling, no pinch, no gestures.

Commercial drivers exist. TouchBridge is a free, user-space alternative. Its goal is to make the touch display feel like it has a trackpad built in.

## Features

- **Touches land on the touch display**, wherever the cursor is. For most gestures the cursor doesn't move at all: events go straight to the app under your finger.
- **Multitouch gestures**: tap, double and triple tap, right-click (hold), scrolling with momentum, pinch to zoom, rotate, click-and-drag, three-finger drag, and moving windows by the title bar.
- **The trackpad's system gestures, with the system's own animations**: Mission Control, App Exposé, switching Spaces, Launchpad, Show Desktop and Notification Center, all opening on the touch display.
- **Back/forward page swipes** in Safari and other apps that support trackpad page swipes. The page slides with your fingers.
- **Follows your trackpad settings** (System Settings → Trackpad), and picks up changes as you make them.
- **Daily reliability**:
  - starts at login and restarts after a crash;
  - recovers after unplugging and sleep;
  - can't leave a mouse button stuck, even across a crash.
- **Touch modes for drawing and multitouch apps**: a Drawing mode, where one finger draws and nothing else gets in the way, and a Multitouch mode that sends all ten fingers to apps that read TUIO.
- **Tracks up to 10 fingers.** Gestures use up to five; Multitouch mode passes on all ten.

## Gestures

| Touch | Result |
|---|---|
| Tap / double-tap / triple-tap | Left click (click count 1, 2, 3) |
| Hold about 0.5 s, then lift | Right-click |
| One-finger drag | Scroll with momentum (default), or click-and-drag (menu setting) |
| Hold, then drag | Click-and-drag (select text, move files) |
| Drag starting on a toolbar, title bar or title text | Move the window |
| Two fingers moving together | Scroll with momentum |
| Two fingers apart / together | Pinch to zoom |
| Two fingers around each other | Rotate |
| Two fingers swiping right / left, in apps with trackpad page swipes such as Safari | Back / Forward. The page slides with your fingers and completes or snaps back when you lift. |
| Two fingers from the right edge, moving left | Notification Center |
| Three fingers moving together | Click-and-drag, grabbing at the centre of the fingers or under the first finger (menu setting) |
| One finger resting on an item, two more added within 1.5 s, then moving | Click-and-drag that grabs exactly where the resting finger first touched |
| Four fingers up / down | Mission Control / App Exposé |
| Four fingers left / right | Switch Space |
| Thumb and three or four fingers pinching in / spreading out | Launchpad / Show Desktop |
| Six or more fingers | Ignored (palm rejection) |

**Where the system gestures appear.** Space switching, Notification Center and Launchpad open on the touch display, not on whichever screen has the cursor or the focused window:
- **Spaces and Notification Center** appear on the display with the cursor. While they open, TouchBridge briefly parks the hidden cursor on the touch display.
- **Launchpad** opens on the display that has the Dock. A pinch-in on the touch display first brings the Dock there, then (by default) sends it back after Launchpad closes.
- **Focus after a Space switch.** macOS moves focus to the switched display. TouchBridge gives it back to the app you were using on the other screen; you can turn this off.

**Trackpad settings.** With "Follow Trackpad Settings" on (the default), each gesture follows its switch in System Settings → Trackpad: three-finger drag, scrolling, momentum, pinch, rotate, Mission Control, Spaces, Launchpad/Desktop and Notification Center.

## Drawing and multitouch apps

**What macOS allows.** macOS has no touchscreen input layer, unlike Windows, iOS and Android. As a result:
- **Apps get one mouse pointer.** That's all an ordinary app can receive.
- **Browsers on a Mac never produce touch events**, so web pages only ever see the mouse.
- **iPhone and iPad apps running on a Mac** get a single touch made from the pointer.

So more than one finger can only reach apps that read a multitouch protocol themselves. TUIO is the standard one: an open protocol from the multitouch-table community, used in creative coding, interactive installations and DIY touch tables.

**The ✋ → Touch Mode menu** picks what touches do. It goes back to Gestures every time TouchBridge starts, so a special mode can't be left on by accident.

| Touch Mode | Icon | What touches do |
|---|---|---|
| Gestures (default) | ✋ | Everything in [Gestures](#gestures) |
| Drawing: One Finger Draws, Nothing Else | ✏️ | The first finger is a pen; every other finger and every gesture is ignored |
| Multitouch Apps: All Fingers as TUIO | 🖐 | Every finger goes to TUIO apps; nothing reaches macOS |

**Drawing mode** suits drawing apps and websites, signature boxes and whiteboards:
- The first finger to touch is a pen: it presses the mouse at touch-down (so a tap makes a dot), drags while it moves, and releases at lift.
- Strokes go through the window server like a real mouse. Canvases check that a mouse button is really pressed while the pointer moves.
- Every other finger, including a palm resting on the screen, is ignored, and so is every gesture.
- When the pen lifts, the next finger to touch draws.

**Multitouch Apps mode** sends every finger, up to ten, as TUIO 1.1 ("2Dcur" cursors) over UDP to `127.0.0.1:3333`. That's the default port of TUIO apps such as TouchDesigner, Processing, openFrameworks, Unity, Max and Kivy.
- Nothing reaches macOS: no clicks and no gestures, so four fingers in your TUIO app won't open Mission Control. Use the trackpad for everything else while this mode is on.
- While nothing touches, TouchBridge sends a frame once a second, as TUIO apps expect.

**Testing.** ✋ → Open Event Sink opens a test window that paints touches:
- in Multitouch mode, every finger in its own colour, marked with its touch number while it's down;
- in Drawing mode, the mouse stroke in grey, which is exactly what an ordinary app receives.

The top line shows fingers now and the most at once. Clear wipes the canvas.

**What won't work, and why.**
- **Touch-only web pages** do nothing at all on a Mac, not even with one finger. These are pages that listen only for touch events, such as many online multitouch testers. The browser never produces those events.
- **Most drawing websites draw one stroke at a time**, even on a tablet. AutoDraw, for example, reads only the first touch.
- **Multi-finger drawing in ordinary apps isn't possible.** They get one mouse.

## Hardware support

**Tested with:**

| | |
|---|---|
| Touch monitor | ARZOPA portable touch monitor, 1920×1080 |
| Touch controller | ILITEK, USB `0x222A:0x0001`, HID multitouch digitizer, 10 contacts |
| Mac | MacBook Pro (Apple silicon, M3 Max), macOS 15.7 |

**Other touchscreens are not supported out of the box.** Everything above the input layer is generic: gesture recognition, delivery to apps, system gestures, page swipes and settings. The input layer, though, is tailored to the tested panel in four places:

1. **The USB IDs** TouchBridge looks for (`0x222A:0x0001`).
2. **The report format**: this controller's byte layout for touch reports, and the feature reads that switch it from single-touch "mouse" mode into multitouch mode after a power cycle.
3. **The display**: the touch monitor is found by its EDID vendor and model numbers.
4. **The physical size** of the panel, used for gesture thresholds in millimetres.

Portable touch monitors often use ILITEK controllers. If yours reports the same USB IDs, it may only need the display numbers changed. Other panels need the report parser adapted. [Adapting to another touchscreen](#adapting-to-another-touchscreen) walks through each step.

## Requirements

- **macOS 15 (Sequoia).** Developed on 15.7; other versions are untested. TouchBridge relies on undocumented event formats that can change between macOS releases (see [Caveats](#caveats)).
- **An Apple silicon Mac.** Intel is untested.
- **A Swift 6 toolchain** (Xcode 16 or later, or the matching command-line tools).
- **No other touchscreen driver** running, such as UPDD or Touchscreen Gestures. They take the panel exclusively, and so does TouchBridge.

## Install

1. **Clone the repository.**
   ```bash
   git clone https://github.com/theofanisv/touch-bridge.git
   ```
   ```bash
   cd touch-bridge
   ```

2. **Create a signing certificate (recommended, one time).** macOS ties the Accessibility permission to the app's signature. An ad-hoc signed build loses the permission every time you rebuild; a stable self-signed certificate keeps it.
   1. Open Keychain Access and choose Keychain Access → Certificate Assistant → Create a Certificate….
   2. Enter the name `TouchBridge Dev`, choose Identity Type "Self-Signed Root" and Certificate Type "Code Signing", and create it.

   To use a certificate with another name, set `TOUCHBRIDGE_SIGN_IDENTITY` when building. Without any certificate, the build falls back to ad-hoc signing and prints a warning.

3. **Build and install.**
   ```bash
   ./scripts/install.sh
   ```
   This does four things:
   - builds `build/TouchBridge.app`;
   - copies it to `~/Applications/TouchBridge.app`;
   - turns on Start at Login;
   - starts it.

4. **Grant permissions.**
   1. Open System Settings → Privacy & Security → Accessibility and switch on TouchBridge. If macOS also asks for Input Monitoring, allow that too.
   2. Restart TouchBridge, because macOS applies new permissions only to a freshly started app: choose ✋ → Quit TouchBridge, then open `~/Applications/TouchBridge.app` again.

5. **Touch the screen.** The ✋ menu shows whether the panel and the touch display were found.

**To update:** pull the latest changes and run `./scripts/install.sh` again. Rebuilding with `./scripts/bundle.sh` never touches the installed copy.

## The menu

TouchBridge lives in the menu bar as ✋. Settings are saved across restarts, except Enabled and Dry Run, which reset at each start.

| Item | What it does |
|---|---|
| Status lines | Panel connection, touch display, the last gesture and how it was delivered, and how many fingers are down |
| Enabled | Turns touch handling on or off. Off hands the panel back to macOS. |
| Touch Mode | Gestures (default), Drawing (one finger draws, nothing else), or Multitouch Apps (all fingers as TUIO, nothing to macOS). Resets to Gestures at each start. See [Drawing and multitouch apps](#drawing-and-multitouch-apps). |
| Delivery | Automatic (default) picks Direct or Warp per gesture (see [How it works](#how-it-works)). "Direct only" and "Warp only" are for testing how an app copes. |
| Pinch & Rotate Direct | Sends pinch and rotate straight to the app (default). Off routes them through the window server instead. |
| One-Finger Drag Scrolls | On (default): one finger scrolls, and holding first then dragging is click-and-drag. Off: one finger drags. |
| Swipe Between Pages (Two Fingers) | Two-finger back/forward page swipes (default on) |
| Follow Trackpad Settings | Gestures follow System Settings → Trackpad (default on). The settings read are listed underneath, one per line. |
| Three-Finger Drag | Three fingers drag. Greyed out while following the trackpad setting. |
| Three-Finger Drag Point | Where a three-finger drag grabs: centre of the fingers (default) or first finger to touch |
| Launchpad on the Touch Display | **Bring the Dock Over, Then Back** (default): the Dock comes over for Launchpad and goes back afterwards. **Bring the Dock Over (it stays)**: the Dock stays on the touch display. **Leave the Dock Where It Is**: Launchpad opens wherever the Dock is. |
| Return Focus to Previous App | After you tap an app on the touch display, gives focus back to the app you were using about 0.6 s later. Off by default: focus follows touch. |
| Keep Focus When Switching Spaces | After a Space switch on the touch display, gives focus back to the app on the other screen (default on) |
| Dry Run (log only) | Recognizes gestures and logs them without sending anything |
| Start at Login | Runs TouchBridge at login and restarts it if it crashes. Quit from the menu stays quit until the next login. |
| Open Event Sink | A test window on the touch display. It logs every event it receives and paints touches: TUIO fingers in colour, the mouse in grey. |
| Open Logs Folder | Opens `~/Library/Logs/TouchBridge/` |

## How it works

```
touch panel ──HID──▶ ReportParser ─▶ ContactTracker ─▶ GestureRecognizer ─▶ DeliveryPolicy ─▶ Deliverer ─▶ apps / macOS
 (seized)            (bytes→contacts) (lifecycles)      (taps, drags,       (Direct or Warp)  (synthesized
                                                         scroll, pinch, …)                     events)
```

**Taking the panel.** TouchBridge opens the touch panel with exclusive access (`kIOHIDOptionsTypeSeizeDevice`), so macOS stops turning touches into cursor movements. It reads the raw multitouch reports itself, parses each finger's position, and tracks contacts across frames. Panel coordinates are mapped onto the touch display's current bounds, updated live when displays are rearranged. Rotation is supported in the mapping but hasn't been tested on hardware.

**Recognizing gestures.** `GestureRecognizer` is pure Swift with no system frameworks, and it is unit tested, including replays of a real panel recording. Nothing is sent until a gesture is classified. Two-finger gestures are classified by how the fingers move:
- both the same way → scroll;
- towards or away from each other → pinch;
- around each other → rotate.

**Delivering to apps.** Each gesture is delivered one of two ways:
- **Direct:** the event is posted straight to the app under the finger (`CGEventPostToPid`). The cursor never moves. AppKit routes a posted event to a window only if it carries the window number in event field 51 and the window-relative location (set with the private `CGEventSetWindowLocation`). For taps, drags and pinches the app is activated first, because macOS ignores clicks aimed at a background window.
- **Warp:** the cursor is hidden, moved to the finger, and returned about 50 ms later. The event goes through the window server like real mouse input. This is used where Direct can't work:
  - window moves and drag-and-drop;
  - the Dock and the menu bar, and pop-up menus;
  - Chromium/Electron apps;
  - the desktop.

**System gestures.** Mission Control, Spaces, Launchpad and Show Desktop are driven by synthesized "dock swipe" events: a type-30 event with subtype 23 plus a type-29 companion. These are the private events the trackpad itself produces, so macOS animates them as usual. Notification Center is opened through its menu-bar clock. Each one appears on the touch display:
- Space switching and Notification Center follow the cursor;
- Launchpad follows the Dock.

**Page swipes.** Each two-finger scroll from a real trackpad comes with a second, hidden stream of gesture events: type 29, subtype 61 at the start, subtype 6 for every movement, subtype 62 at the end. AppKit's swipe tracking (behind Safari's back/forward swipe) measures progress from that stream, not from the scroll events. TouchBridge sends the stream with two-finger scrolls, so apps animate the swipe natively.

**Touch modes.**
- **Drawing:** a separate path in `GestureRecognizer`. The first finger becomes a pen, delivered as a Warp drag so the mouse button is really down system-wide. Everything else is dropped.
- **Multitouch Apps:** gesture recognition is skipped entirely. Each frame of contacts becomes a TUIO bundle: `TUIOSessions` gives every touch its own session id and a velocity, and `TUIO.frame` builds the OSC bytes, sent over UDP.

**Staying reliable.**
- **Multitouch mode:** after unplugging or sleep, the panel starts in a single-touch "mouse" mode. TouchBridge switches it back to multitouch when it connects, and again whenever mouse-mode reports appear.
- **Stuck buttons:** every open press is journaled to disk, so a restart after a crash releases it where it was made.
- **Login item:** a per-user launch agent starts TouchBridge at login and restarts it after a crash.

The design history is in `docs/`, including findings, experiments that failed and why:
- `docs/spec.md`: the original plan plus implementation notes;
- `docs/backlog.md`: per-feature investigations and decisions.

## Adapting to another touchscreen

You'll change a few constants and possibly the report parser, then rebuild.

1. **Find the panel's USB IDs.** Open System Information → USB, or run:
   ```bash
   ioreg -p IOUSB -l -w0 | grep -E '"USB Product Name"|"idVendor"|"idProduct"'
   ```
   Set `vendorID` and `productID` in `Sources/TouchPlatform/HIDTouchSource.swift`.

2. **Record the panel's reports.** With nothing else holding the panel, build with `./scripts/bundle.sh`, then run:
   ```bash
   open -n build/TouchBridge.app --args --probe 90
   ```
   Touch with one, two and three fingers. `~/Library/Logs/TouchBridge/` gets the raw reports (`probe-*.jsonl`) and a summary.

3. **Adapt the parser.** `Sources/TouchCore/ReportParser.swift` decodes the tested panel's layout: report ID 4, ten 5-byte contact slots (ID and tip switch, X and Y as little-endian 16-bit values up to 16384 and 9600), and the contact count at byte 55. Compare it with your recording and your panel's HID report descriptor. Adjust the report ID, slot size, offsets and logical maximums. Add your recording as a replay test next to `Tests/TouchCoreTests/Fixtures/`.

4. **Point it at your display.** Run the read-only probe:
   ```bash
   open -g -n build/TouchBridge.app --args --ax-probe --menubar
   ```
   `axprobe.log` lists every display with its vendor and model numbers. Set `displayVendor` and `displayModel` in `PipelineSettings` (`Sources/TouchPlatform/InputPipeline.swift`). The self-test in `SystemUISelfTest.swift` uses the same numbers.

5. **Set the physical size.** Set `panelWidthMm` and `panelHeightMm` in `GestureConfig` (`Sources/TouchCore/GestureRecognizer.swift`) to the panel's active area. Gesture thresholds are in millimetres.

6. **Check the multitouch switch.** The tested panel needs feature reports 2 and 6 read before it leaves single-touch mode (`requestMultitouchMode` in `HIDTouchSource.swift`). Your panel may need something different, or nothing.

7. **Test and install.**
   ```bash
   swift test
   ```
   ```bash
   ./scripts/install.sh
   ```

Making all of this automatic would be the natural next step: parsing any standard HID multitouch panel from its descriptor, a display picker in the menu, and the physical size from the display's EDID. If you adapt TouchBridge to another panel, please consider sharing the changes.

## Logs and diagnostics

Logs are in `~/Library/Logs/TouchBridge/`:
- `touchbridge.log`: every gesture, and how and where it was delivered;
- `eventsink.log`: what the Event Sink test window received;
- other files from the diagnostic modes below.

Diagnostic modes run on the development build (`build/TouchBridge.app`, made by `./scripts/bundle.sh`). Most run next to the installed copy. The ones marked † need the panel, or the single running instance, so quit the installed copy first (✋ → Quit TouchBridge).

| Command (`open -n build/TouchBridge.app --args …`) | What it does |
|---|---|
| `--probe 90` † | Records raw panel reports for 90 s |
| `--dry-run` † | Recognizes and logs gestures without sending anything |
| `--event-sink` | Opens the Event Sink test window. It logs every event it receives, including those AppKit's swipe tracker takes first, and paints TUIO fingers (listening on port 3333) and mouse strokes. |
| `--direct-selftest` | Posts test events to the Event Sink only (`--swipe` adds the page-swipe variants) |
| `--ax-probe --map` | Read-only map of the window-drag areas on screen |
| `--ax-probe --menubar` | Read-only report: displays, menu bars and clocks, active menu-bar display, current Spaces, the Dock |
| `--restart-selftest` † | Starts, stops and restarts the panel input |
| `--dockswipe-selftest` | Posts Mission Control dock swipes and closes them again. **Visible on screen.** |
| `--system-ui-selftest` | Opens and closes Notification Center and Launchpad (`--nc`, `--launchpad`, `--move-dock`, `--spaces`) and logs where each appeared. **Visible on screen.** |

Add `-g` after `open` to keep a diagnostic run in the background.

## Troubleshooting

**Touching does nothing.**
- Another touchscreen driver may be holding the panel. Quit or uninstall it, then use ✋ → Enabled, or restart TouchBridge.
- The ✋ status lines say whether the panel and the display were found.

**Touches move the cursor, or land on the wrong screen.** TouchBridge isn't running or isn't enabled, so macOS is handling the panel itself.

**The panel is found but apps don't react.** Accessibility permission is missing, or was granted to a differently signed build. Switch it off and on again in System Settings → Privacy & Security → Accessibility, then restart TouchBridge.

**Only one finger works after replugging.** TouchBridge asks the panel for multitouch mode automatically and logs it. If it persists, unplug the panel's USB cable and plug it back in.

**A gesture behaves differently from the trackpad.** Check "Follow Trackpad Settings" and the trackpad switches listed under it.

**One app ignores taps.**
- Try ✋ → Delivery → Warp only (testing) to compare.
- Chromium/Electron apps already use Warp automatically.

**Page swipes don't work in an app.** The app must support trackpad page swipes, and "Swipe between pages" must be on in System Settings → Trackpad → More Gestures.

**Gestures get in the way of drawing.** Use ✋ → Touch Mode → Drawing: one finger draws, and every other finger and gesture is ignored.

**Multitouch mode does nothing in my apps.** That's by design. In Multitouch mode fingers go only to apps that read TUIO, and nothing is delivered to macOS. Ordinary apps, web pages, and iPhone or iPad apps can't receive more than one finger on a Mac. Use the Event Sink to check that the fingers arrive.

**A web page ignores touches completely.** It probably listens only for touch events, which browsers on a Mac never produce. TouchBridge reaches web pages as a mouse.

## Uninstall

1. ✋ → turn off Start at Login, which removes the launch agent. Then ✋ → Quit TouchBridge.
2. Move `~/Applications/TouchBridge.app` to the Trash.
3. Optionally, remove TouchBridge's files and settings:
   - `~/Library/Logs/TouchBridge/`
   - `~/Library/Application Support/TouchBridge/`
   - the saved settings, with this command:
     ```bash
     defaults delete com.theofanis.touchbridge
     ```
4. Remove TouchBridge from System Settings → Privacy & Security → Accessibility.

## Development

```bash
swift test
```
```bash
./scripts/bundle.sh
```
```bash
./scripts/install.sh
```

- `swift test` runs the unit tests, the delivery tests and the replay of a real panel recording.
- `./scripts/bundle.sh` builds and signs `build/TouchBridge.app` for development.
- `./scripts/install.sh` builds, installs to `~/Applications` and restarts the login item.
- `CHANGELOG.md` lists the changes in each version.

| Path | Contents |
|---|---|
| `Sources/TouchCore` | Pure Swift: report parser, contact tracker, coordinate mapping, gesture recognizer, delivery policy, focus and Dock logic. No system frameworks; fully unit tested. |
| `Sources/TouchPlatform` | macOS I/O: HID input, displays and windows, event synthesis, Direct and Warp delivery, system gestures, diagnostics |
| `Sources/TouchBridgeApp` | The menu-bar app: menu, saved settings, login item, Event Sink, probe |
| `Tests` | Unit tests and replays; `Tests/TouchCoreTests/Fixtures` holds the panel recording |
| `docs` | The original plan with implementation notes (`spec.md`) and per-feature investigations (`backlog.md`) |

## Caveats

- **Private APIs.** TouchBridge depends on undocumented CoreGraphics, SkyLight and IOKit behaviour:
  - event fields and gesture subtypes learned by observing real trackpad events;
  - a few private calls, looked up at runtime.

  A macOS update can break individual features; where a private call is missing, that feature turns off and the rest keeps working. This is not App Store material.
- **One tested setup.** It's a personal project, tested on one monitor, one Mac and one macOS version.
- **The cursor is borrowed briefly.** Warp delivery and some system gestures move the hidden cursor for a fraction of a second. If you're using the trackpad at that exact moment, the cursor returns to where it was before.

## Credits

- [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) by Noah Nuebling: its `TouchSimulator` showed the format of the trackpad's dock-swipe events.
- WebKit's CoreGraphics SPI headers: names and numbers for gesture event fields.

## License

MIT. See [LICENSE](LICENSE).
