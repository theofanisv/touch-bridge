# TouchBridge: a user-space touchscreen driver for the ARZOPA display

> Working name **TouchBridge**. UPDD (Universal Pointing Device Driver) is Touch-Base Ltd's commercial product name, so we use our own name. It can be renamed at any point.
> Location: `~/Projects/TouchBridge`. Step 1 of execution copies this plan into it as `docs/spec.md`.

## Context

The ARZOPA portable monitor has a built-in touch panel. macOS has no touchscreen support. Apple's generic HID driver treats the panel as an absolute pointer and maps each touch onto **whichever display the cursor is on**. Touching the ARZOPA while the cursor is on the MacBook therefore clicks the matching point on the MacBook screen.

The trial app "Touchscreen Gestures" fixes the mapping but has no multitouch, and you plan to remove it. The goal is our own small agent that:

- makes touch act on the ARZOPA at the touched point;
- keeps the visible cursor on the MacBook screen;
- supports tap, double-tap, drag, long-press right-click, two-finger scroll, pinch to zoom, rotate, and back/forward.

## Verified facts about this Mac

| Item | Value |
|---|---|
| Mac | MacBook Pro M3 Max (Mac15,11), macOS 15.7.3, Xcode 26.3, Swift 6.2.4, SIP on |
| Signing | **No code-signing identity** in the keychain |
| Displays | Built-in XDR (main) + **ARZOPA** 1920×1080@60. EDID vendor 7908, model 342. "Displays have separate Spaces" is ON, so ARZOPA has its own menu bar |
| Touch panel | **ILITEK-TOUCH**, USB VID `0x222A` PID `0x0001`, PrimaryUsage 0x0D/0x04, 64-byte reports, claimed by Apple's `AppleUserHIDEventDriver` |
| RID 4 (multitouch) | 10 slots × 5 bytes, starting at byte 1. Per slot: `b0` bits 0-5 = contact id, bit 6 = tip; X = LE16 (0–16384); Y = LE16 (0–9600). Then ScanTime LE32 @51, ContactCount @55, padding to 64 |
| RID 5 (mouse fallback) | buttons @1, X LE16 @2, Y LE16 @4 (same ranges) |
| Features | RID 2 = Contact Count Max (10). RID 6 = 256-byte vendor blob. No Input-Mode feature, so the host can't switch the panel's mode |
| Physical size | 309.3 × 173.9 mm, about 6.2 px/mm |
| Conflict | Touchscreen Gestures holds the panel exclusively (pid 69097). Its log shows a **non-root** process can seize the device once Accessibility is granted |
| Prefs | Two-finger swipe navigation is ON, so a horizontal two-finger scroll already means back/forward in Safari and Chrome |

## Decisions (confirmed with you)

- **User-space agent.** A signed Swift menu-bar app; not DriverKit, no SIP changes.
- **Direct-to-app delivery.** The cursor never moves: events go straight to the app under your finger with `CGEventPostToPid`, and focus doesn't change. Some gestures in some apps can't work that way. Those automatically use the **Warp** fallback: cursor hidden, jumps, acts, returns.
- **v1 features:** tap, double-tap and triple-tap, drag, long-press right-click, two-finger scroll with momentum, pinch to zoom, two-finger rotate, back/forward.
- **Not in v1:** three-finger Spaces/Mission Control, calibration screen.

## Architecture

```
TouchBridge/                         (SwiftPM, no .xcodeproj)
  Package.swift
  Sources/TouchCore/                 pure Swift, no system frameworks, fully unit-tested
    ReportParser.swift               RID 4 → TouchFrame; RID 5 → single contact
    ContactTracker.swift             began/moved/ended per contact id, lift timeout, >3 contacts = palm → cancel
    CoordinateMapper.swift           normalized → global CG point (display bounds, rotation 0/90/180/270)
    GestureRecognizer.swift          state machine, injectable clock → [GestureAction]
    Config.swift                     Codable thresholds and per-app overrides (~/Library/Application Support/TouchBridge/config.json)
  Sources/TouchPlatform/             macOS I/O
    HIDTouchSource.swift             IOHIDManager for matching/removal only; IOHIDDeviceOpen(dev, Seize);
                                     timestamped input-report callback; serial user-interactive queue
    DisplayLocator.swift             find ARZOPA by vendor/model/serial; bounds, rotation; reconfiguration callback
    WindowLocator.swift              one CGWindowListCopyWindowInfo hit test per gesture → pid, window number, layer, owner
    DeliveryPolicy.swift             picks Direct or Warp once per gesture (table below)
    DirectDelivery.swift             CGEventPostToPid; location, fields 91/92 = window number, clickState, event number,
                                     current modifier flags; tag field 42
    WarpDelivery.swift               save cursor → (dlsym'd cursor-hide, optional) → post at HID tap → warp back
                                     (CGWarpMouseCursorPosition + CGAssociateMouseAndMouseCursorPosition)
    ScrollSynth.swift                CGEvent scroll, pixel units, continuous=1; phase field 99 (bitmask 1/2/4/8/128);
                                     momentum field 123 (0/1/2/3, NOT a bitmask); own momentum generator
    GestureSynth.swift               private gesture events: type 29 via field 55; subtype field 110 (Zoom 8, Rotation 5,
                                     NavigationSwipe 16); amounts in 113/114; direction in 115; phase in 132
    PressJournal.swift               records target pid + pressed button; sends mouse-up on quit, disable or relaunch
  Sources/TouchBridgeApp/            NSStatusItem menu, onboarding, --probe mode, SMAppService agent
  Tools/EventSink/                   test app that logs every received event (used for the M1 compatibility matrix)
  Tests/TouchCoreTests/              unit tests + replay of recorded fixtures (golden action sequences)
  scripts/bundle.sh                  swift build → TouchBridge.app (Info.plist LSUIElement,
                                     Contents/Library/LaunchAgents/*.plist) → codesign with stable identity
```

**Data flow:**

1. The HID report callback (serial queue, an `actor InputPipeline`) feeds `ReportParser`, then `ContactTracker`, then `GestureRecognizer`.
2. Each `GestureAction` goes to `DeliveryPolicy`, which uses `WindowLocator` once per gesture.
3. The action is then sent through Direct or Warp delivery, using `ScrollSynth` or `GestureSynth` where needed.
4. `CoordinateMapper` uses `DisplayLocator`'s bounds, which update live when displays change.

**Permissions:**

- Accessibility (needed to post events, and on this Mac it also unlocks the seize).
- Input Monitoring is requested only if opening the device still returns `kIOReturnNotPermitted`.
- Grants apply only to a new process, so onboarding relaunches the app.
- Signing with a stable self-signed certificate keeps the grants across rebuilds.

## Gesture rules (thresholds in mm, converted with 6.2 px/mm)

- **Nothing is posted until the gesture is classified.** Delivery is then fixed for the whole gesture, never switched halfway.
- **Tap:** lift within 250 ms, moved less than 3 mm. **Double/triple-tap:** within `NSEvent.doubleClickInterval`, within 8 mm. Snap to the first tap's point and send clickState 2/3. Never delay the first click.
- **Long-press:** hold ≥ 500 ms without moving → right-click on lift.
- **Drag:** movement > 3 mm before 500 ms → left drag. **Hold-then-move:** drag-and-drop, always Warp.
- **Two fingers:** the second contact lands within 150 ms. The gesture locks to one of:
  - **scroll**: centroid moves; phased, with momentum;
  - **pinch**: finger distance changes by more than 10% → magnify;
  - **rotate**: angle changes by more than 10° → rotation.
- **Back/forward = horizontal two-finger scroll.** It is not a separate gesture, which would navigate twice. Some apps only respond to swipe events; for those, an optional per-app setting sends the NavigationSwipe (16) event instead.
- **More than 3 contacts** (palm): cancel. **Move events** are throttled to 60 Hz; phase changes are never coalesced. **Hover:** none in Direct mode.

## Delivery policy

| Gesture | Default | Forced to Warp when… |
|---|---|---|
| Tap / double / triple / long-press right-click | Direct | any rule below |
| Immediate drag | Direct | title-bar zone (top 28 pt of the window or AX title bar), because WindowServer moves windows using the real cursor |
| Hold-then-drag (drag-and-drop) | **Warp** | always |
| Two-finger scroll | Direct | any rule below |
| Pinch / rotate | Direct if M1 proves apps accept them, otherwise Warp | any rule below |

**Rules that force Warp, checked in order:**

1. Your per-app override.
2. The app bundles Electron/CEF/Chromium frameworks (scanned once, cached).
3. The window belongs to Dock, SystemUIServer, ControlCenter, NotificationCenter, Spotlight or WindowServer.
4. The window layer is not 0 or 3.
5. A popup menu (layer 101) is open, since a menu tracks the real cursor.
6. No window is under the finger.

**Focus:** "Activate app on tap" is an option, **off by default** as you chose. M1 will show whether controls swallow the first click in inactive windows. If so, we revisit this together.

## Milestones (each ends with a gate; stop and check with you at each gate)

**M0: Preparation** (I ask before each command that changes the system)
- You create a self-signed code-signing certificate ("TouchBridge Dev", 10 years) in Keychain Access → Certificate Assistant. I'll give exact clicks. No Apple ID needed.
- Pause Touchscreen Gestures without uninstalling it:
  - quit its menu app;
  - `launchctl bootout gui/501/com.touchscreen.gestures` and `…/com.touchscreen.gestures.maintenance`;
  - then `launchctl disable` for both labels, because KeepAlive and the 10-minute maintenance job would restart it.
- To undo: `launchctl enable` + `launchctl bootstrap gui/501 ~/Library/LaunchAgents/<plist>`.
- *Gate:* ioreg shows no Touchscreen Gestures user client on the ILITEK device.

**M1: Probes (answers the questions that decide everything else)**
- (a) `TouchBridge.app --probe` seizes the panel and records raw frames to JSON: 1, 2 and 10 fingers, lift frames, ScanTime units, report rate, any RID 5 traffic, unplug and replug. It also reads feature reports 2 and 6 (safe reads).
  - *Gate:* **RID 4 shows ≥ 2 simultaneous contacts.** If only RID 5 arrives, multitouch isn't possible on this panel, and v1 becomes single-touch plus long-press.
- (b) EventSink plus a compatibility matrix:
  - gestures: tap, double-tap, drag, right-click, scroll, pinch, rotate;
  - × apps: EventSink, Finder, Safari, TextEdit, Preview, Maps, Terminal, System Settings, Chrome, VS Code, PhpStorm, Teams;
  - × modes: Direct and Warp.
  - *Gate:* the results fix the policy table and the focus default.
- (c) DisplayLocator finds ARZOPA and correct bounds at rotation 0 and 90.

**M2: TouchCore, tests first**
- Parser, tracker, mapper (rotation and mirroring), recognizer, config.
- *Gate:* `swift test` is green, and replaying the M1 recordings yields the expected golden action sequences.

**M3: Single touch end to end**
- Menu-bar app (enable/disable, status incl. "panel held by \<app>" read from ioreg, ARZOPA picker, quit), onboarding, seize, policy, Direct and Warp delivery, press journal, and a dry-run mode that logs instead of posting.
- *Gate:* checklist items 1–11.

**M4: Two fingers**
- Scroll with momentum, pinch, rotate.
- *Gate:* checklist items 12–13.

**M5: Hardening**
- Hotplug, sleep/wake, display rearrangement/resolution/mirroring, login agent via `SMAppService.agent(plistName:)` (KeepAlive on crash, Aqua session only), single-instance lock, per-app override menu, `os_log` (subsystem `com.theofanis.touchbridge`).
- *Gate:* items 14–20, idle CPU about 0%, touch-to-event latency p95 < 15 ms.
- **After that you uninstall Touchscreen Gestures.**

## Verification checklist (on the hardware)

1. Corners and centre land within 2 mm with the cursor on the MacBook; the cursor does not move.
2. Same with the cursor on ARZOPA.
3. Rearranging displays: no restart needed.
4. Rotation 90/180/270.
5. Resolution/scaling change; mirroring on and off.
6. Unplug the touch USB, then the whole monitor: it resumes within 2 s.
7. Sleep/wake and lid close.
8. Quit gives back native behaviour; `kill -9` leaves no stuck button and the agent restarts.
9. TextEdit: double-tap selects a word, triple-tap a paragraph.
10. Long-press shows a context menu; tapping an item works.
11. Text-selection drag, Finder drag-and-drop, title-bar window move (no jump).
12. Safari: scroll, momentum, rubber-band; exactly one back-navigation per swipe.
13. Pinch and rotate in Preview and Maps.
14. ARZOPA menu bar, Dock, Control Center, notification banners.
15. 10 fingers or a palm: no stray clicks.
16. Using the trackpad during a touch drag.
17. Chrome, Teams, VS Code: click, scroll, double-click.
18. Typing after a tap goes where expected (given the focus setting).
19. Permissions survive a rebuild.
20. Energy use in Activity Monitor.

Automated: `swift test` (TouchCore unit + replay tests). Logs: `log stream --predicate 'subsystem == "com.theofanis.touchbridge"'`.

## Safety and rollback

- Quitting or crashing releases the panel automatically, so macOS falls back to its default behaviour. The menu has Disable and Quit.
- The press journal and quit handlers send a mouse-up for any held button.
- Touchscreen Gestures stays installed (only paused) until M5 passes, so you can switch back with two commands.
- Nothing runs as root, nothing touches SIP, no kernel or system extensions.

## Risks

- **Private gesture fields (pinch/rotate/nav-swipe)** could break in a future macOS. If they do, those gestures turn off and everything else keeps working.
- **Direct-mode app compatibility.** Mitigated by the Warp rules and per-app overrides.
- **The panel might send multitouch only after a host request.** M1 checks this; the fallback is single touch.
- **The private cursor-hide call** is looked up at runtime. Without it, the cursor is briefly visible during Warp gestures.

## References

- Mac Mouse Fix `TouchSimulator.m` (gesture field usage): https://github.com/noah-nuebling/mac-mouse-fix
- WebKit `CoreGraphicsTestSPI.h` (fields 110/113): https://webkit.googlesource.com/WebKit/+/54591b58a50e66aaad868f829cfce9d38eafed7b/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h
- mac-cua (CGEventPostToPid delivery and limits): https://glama.ai/mcp/servers/hyprcat/mac-cua
- SDK `CoreGraphics.framework/Headers/CGEventTypes.h` (fields 0, 1, 42, 88, 91, 92, 93–100, 123)

---

## Implementation notes (2026-10-09)

Findings from building and testing on the hardware. These override the plan where they differ.

- **Panel:** sends only RID 4 frames, up to 10 contacts, about 143 Hz. It reports every frame while a finger is still, and sends one final tip=0 frame at lift. It needs no mode switch. UPDD, when it was installed, claimed the panel at USB level, so no HID device existed.
- **HID:** IOHIDManager's device objects are already activated, and `IOHIDDevice.h` requires every Register call before activation. So each match gets its own `IOHIDDeviceCreate` device: open (seize), register, set the queue, then activate.
- **Direct delivery:**
  - `CGEventPostToPid` alone reaches the app with `windowNumber = 0`. AppKit reads the window from **field 51**, not 91/92, and needs the window-relative location, top-left origin, set with the private **`CGEventSetWindowLocation`**. Found by diffing window-server-routed events against posted ones in the Event Sink (`DirectTarget`).
  - On an inactive app, clicks are swallowed (first-click rule) and pinches dropped; right-click and scroll arrive. So taps, drags, pinches and rotates activate the target app first (`NSRunningApplication.activate()`, no delay needed). The owner chose "focus follows touch" as the default, with a menu option to return focus.
  - Standard controls (NSButton) fire on Direct taps. An early report to the contrary was taps 2–5 pt outside the button's bezel.
- **Gestures (owner feedback):**
  - Two-finger gestures are classified by finger motion: together → scroll, apart/together → pinch, around → rotate, decided after 4 mm of travel. The first version's "first threshold wins" turned sloppy scrolls into pinches.
  - One-finger drag scrolls by default; hold-then-drag is click-and-drag.
- **Window moves:** the window server performs them by following the real cursor, so they use Warp. The draggable area comes from the Accessibility API (`WindowDragRules`): toolbars (including their buttons, for pans), plain title bars and title text, but not text fields, tabs or value controls. Where Accessibility can't tell (Electron apps) or doesn't answer within 80 ms, the original 28 pt band applies. The fixed 28 pt band missed most of Safari's roughly 50 pt toolbar.
- **Robustness (fixes from code review):**
  - Disable → Enable creates a fresh IOHIDManager, because a cancelled one hits an IOKit assert.
  - `Deliverer.abortGesture()` closes momentum, open phases and pressed buttons, and returns the cursor. It runs on Disable, on Quit, and when the touch display disappears mid-gesture.
  - A Direct gesture that interrupts a Warp gesture returns the cursor immediately.
  - Chromium/Electron apps are never queried through Accessibility, because queries make them build their accessibility tree.
  - **Crash recovery (v0.6.3, review finding 5):** the press journal records where a press was made, and, for Direct presses, the window, its origin and the app's bundle id. After a crash, the restarted app releases the press there.
    - Direct: on the same window, with no cursor movement, and only if the same app still runs under that pid.
    - Warp: at the press point through the window server, so a drag that was under way drops back where it started.
    - Before, the release went to the cursor's position on the other display, without window fields, or to whichever app had inherited the pid.
- **System gestures (2026-10-10):**
  - **Dock swipes:** Mission Control, App Exposé, Spaces, Launchpad and Show Desktop are synthesized as the trackpad's private "dock swipe" events (`DockSwipe`, format from Mac Mouse Fix):
    - per step, a type-30 event with subtype 23 (`kIOHIDEventTypeDockSwipe`), phase, swipe type and accumulated progress, followed by a type-29 companion, both posted to the session tap;
    - the end event is re-sent after 0.2 s and 0.5 s.
  - **Swipe types on macOS 15, verified on screen:** 1 = horizontal (Spaces), 2 = vertical (Mission Control up, App Exposé down), 3 = pinch (needs the inverted flag: in = Launchpad, out = Show Desktop). Type 4 does nothing.
  - **Notification Center:** opened through the menu-bar clock.
  - **Which display each appears on** (owner report, `--ax-probe --menubar`):
    - Notification Center opens on the display whose clock is used. Accessibility only exposes the clock of the active menu bar (the display with the focused window), and the inactive display's menu bar answers no Accessibility hit-tests.
    - Space switching acts on the display with the active menu bar.
    - Launchpad ignored focus and opened on the MacBook, where the cursor was. The Dock imports both `CGSCopyActiveMenuBarDisplayIdentifier` and `CGSGetCurrentCursorLocation`.
  - **Self-test (2026-10-11, `--system-ui-selftest`):** Notification Center opens on the display with the cursor, whatever the active menu bar; warping the hidden cursor is enough. Launchpad opened on the MacBook with the cursor and the active menu bar on the ARZOPA, so it follows the Dock's display or the main display.
  - **v0.5.2:** Notification Center: press the clock with the hidden cursor on the touch display for 0.8 s (the v0.5.1 click below was replaced). Pinches no longer park the cursor.
  - **Launchpad follows the Dock** (self-test lp-4). The Dock moves to a display when the cursor pushes against its bottom edge, and synthetic mouse-moved events with a downward delta do that.
  - **v0.5.3:** a pinch-in on the touch display brings the Dock there first, as a setting: bring over (default), bring over then back, or leave (`LaunchpadDock`, `DockLocator`, `Deliverer.nudge`).
  - **v0.6.2 (back/forward, final):** real trackpad page swipes. Two-finger scrolls carry the trackpad's scroll-gesture stream (type 29: subtype 61, then 6 per move, then 62). AppKit's swipe tracking measures progress from it. It was found with a per-process event tap, since the tracker pulls those events before any app-level monitor. It replaces the flick.
  - **v0.6.0 (back/forward):** the animated page swipe can't be synthesized (backlog 5). A quick horizontal two-finger flick sends back/forward to the window under the fingers, only in apps where ⌘[ / ⌘] mean history. There's a menu switch. v0.6.1: it presses the app's ⌘[ / ⌘] menu item through Accessibility, because Safari ignored the shortcut posted to it.
  - **v0.5.9 (three-finger drag):** rest a finger, add two. Two fingers joining a resting first finger within 1.5 s start a three-finger drag that grabs under the resting finger (`restingDragWindowNs`). v0.5.10: at the point where that finger first touched, then following its movement.
  - **v0.5.7–0.5.8:** after a Space switch on the touch display, macOS moves focus there. When another display had the active menu bar, that app is re-activated once, within 1.5 s; a new touch cancels this (`FocusKeeper`). It's a setting, "Keep Focus When Switching Spaces", on by default.
  - **v0.5.6:** Space switching follows the cursor, not the active menu bar (self-test `--spaces`). The focusing step was removed; only the hidden cursor waits on the touch display.
  - **v0.5.5:** "then back" is the default.
  - **v0.5.4:** with "then back" the Dock lives off the touch display. It returns after every Launchpad opened by touch, and when the menu item is chosen. Moving the Dock over took 202 ms on the owner's first try.
  - **Targeting (v0.5.1; owner's test: Spaces work, Notification Center and Launchpad still open on the MacBook; see backlog "Next session"):**
    - Notification Center: if the active clock isn't on the touch display, click the touch display's own clock (Warp), only after the window list confirms a ControlCenter status item at that point.
    - Spaces and Launchpad: the hidden cursor waits on the touch display until 0.8 s after the swipe ends.
    - Spaces only: when another display has the active menu bar, focus the window under the fingers (Accessibility raise and main, then activate), and hold the swipe until the touch display has the active menu bar (at most 250 ms; `DockSwipeHold`).
    - The log records the active menu bar at each swipe and the display whose Space changed.
