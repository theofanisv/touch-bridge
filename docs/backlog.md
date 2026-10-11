# TouchBridge backlog

Requested by the owner on 2026-10-09. Items marked "done" shipped; their notes are kept for reference. Open: 0, 5, 7.

## Next session (planned 2026-10-10 for 2026-10-11)

**Owner's test of v0.5.1:** Space switching works on the ARZOPA. Notification Center and Launchpad don't: both still open on the MacBook.

**Evidence from the log and read-only probes:**
- **Notification Center:**
  - All four triggers fired: three Accessibility presses of a clock on the ARZOPA, one Warp click on the ARZOPA's clock.
  - Yet touches on the ARZOPA 1–2 s later hit Preview and Finder, not Notification Center, whose window covers its whole display while open. Its window stays parked on the MacBook (0,0,1728×1117).
  - It once opened on the ARZOPA (01:03), when the owner's cursor was probably there.
  - Likely rule: it opens on the display with the **cursor**. The Warp click returned the cursor after 50 ms, probably too early.
  - Its binary imports `CGSCopyActiveMenuBarDisplayIdentifier`, `CGGetDisplaysWithPoint` and `CGMainDisplayID`. AppKit's mouse position doesn't appear as an import.
- **Launchpad:**
  - Opened on the MacBook every time: with the active menu bar on either display, and with the hidden cursor parked on the ARZOPA throughout.
  - The auto-hidden Dock is on the MacBook (its tile list sits at y = 1117). The MacBook is also the main display.
  - Likely rule: the **Dock's display** or the **main display**. Warping the cursor sends no mouse-moved events, so the Dock may not see the cursor on the ARZOPA at all.
- **Space switching:** worked both with the window under the fingers focused first and with the cursor parked. Each try did both, so it isn't known which one mattered.

**Plan:**
1. With the owner watching, run `open -g -n build/TouchBridge.app --args --system-ui-selftest`. It opens and closes Notification Center and Launchpad a few times, takes about 30 s, and logs where each landed to `~/Library/Logs/TouchBridge/systemui.log`. Variants:
   - Notification Center:
     - nc-1: press, cursor untouched;
     - nc-2: press, cursor held on the ARZOPA;
     - nc-3: as nc-2, plus mouse-moved events;
     - nc-4: click the ARZOPA clock, cursor back after 50 ms (today's behaviour);
     - nc-5: click, cursor held 1 s.
     - The presses run first, while the MacBook still has the active menu bar.
   - Launchpad:
     - lp-1: pinch, cursor held (today's behaviour);
     - lp-2: as lp-1, plus mouse-moved events;
     - lp-3: open Launchpad.app, cursor on the ARZOPA.
   - Optional `--move-dock` (ask the owner first): lp-4 pushes the Dock to the ARZOPA's bottom edge, opens Launchpad, then moves the Dock back.
2. Apply what works:
   - Notification Center: most likely, keep the hidden cursor on the ARZOPA about 0.8 s while it opens.
   - Launchpad: mouse-moved events while parked. If it follows the Dock, ask whether the Dock may move to the ARZOPA when Launchpad is opened there. If it only ever uses the main display, document it as a macOS limitation; changing the main display is a system setting, so it stays the owner's call.
   - **Results (2026-10-11, `systemui.log`):**
     - nc-1 (cursor on the MacBook): MacBook. nc-2 and nc-3 (hidden cursor on the ARZOPA, with the MacBook holding the active menu bar): **ARZOPA**. nc-5 (click, cursor held): ARZOPA. nc-4 was confounded: the previous panel was still closing.
     - So Notification Center opens on the display with the cursor; warping alone is enough. **v0.5.2:** press the clock with the hidden cursor on the touch display for 0.8 s, and log where the panel opened ("notification center result").
     - lp-1 to lp-3 (pinch, pinch with mouse-moved events, Launchpad.app; cursor and active menu bar on the ARZOPA): **MacBook** every time. Launchpad follows the Dock's display or the main display. v0.5.2 no longer parks the cursor for pinches.
     - lp-4 (`--move-dock`, run with the owner's OK): the synthetic push moved the Dock to the ARZOPA, and Launchpad then opened **there**. Launchpad follows the Dock's display.
     - **v0.5.3:** menu "Launchpad on the Touch Display". The owner chose a setting with all three options, defaulting to "bring the Dock over, it stays":
       - Bring the Dock Over: the pinch is held while the hidden cursor pushes against the touch display's bottom edge, checking about every 45 ms (at most 1.5 s), then released.
       - Then Back: `DockReturnWatch` pushes the Dock home once Launchpad has closed and no finger is on the panel.
       - Leave: no change.
     - **Owner test of v0.5.3:** Notification Center correct on both screens. Launchpad opened on the ARZOPA from touch **and trackpad**, in every mode. The first "bring over" left the Dock on the ARZOPA, and "then back" only returned a Dock it had moved itself.
     - **v0.5.4:** "then back" returns the Dock after every Launchpad opened by touch, wherever it was found (`LaunchpadDock.plan`/`home`: home is the display it came from, else the main display). Choosing the menu item sends a Dock found on the touch display home. Owner's test: works (over in about 200 ms, back in about 195 ms).
     - **v0.5.5:** "then back" is the default (owner's choice).
     - **Declined: Launchpad on both screens at once.** macOS draws Launchpad once, on the Dock's display. Showing it on both would mean mirroring its picture through screen capture: Screen Recording permission, a mirror window, and touches mapped back. The owner asked for it only if it stays simple.
   - **Clean-up done (v0.5.6):** `--system-ui-selftest --spaces` switched a Space with the hidden cursor on the ARZOPA, nothing focused, and the MacBook holding the active menu bar. The **ARZOPA**'s Space changed, then switched back. Space switching follows the cursor, so the focusing step (and its wait for the active menu bar) was removed.
   - **Owner test of v0.5.6:** the switch works, but the MacBook window lost focus (macOS moves focus to the switched display). **v0.5.7–0.5.8:** when the MacBook had the active menu bar at the start of the swipe, `FocusKeeper` re-activates that app the first time focus moves away within 1.5 s. A new touch cancels it. The owner asked for it as a setting: menu "Keep Focus When Switching Spaces", on by default; off is the v0.5.6 behaviour.
3. Optional clean-up: try a Space switch with the cursor parked but no focusing. If it still switches on the ARZOPA, drop the focusing step to remove a side effect.
4. Commit and push v0.5.x once the owner says so, after the personal-data scan and tests.
5. Then the items parked for the end: 0 (three-finger grab precision) and 5 (back/forward swipe).

## 1. Follow the Mac's trackpad settings (done in v0.4.0)

Shipped with a "Follow Trackpad Settings" master switch. The keys are polled every 3 s and after wake instead of a file watcher.

Mirror the owner's trackpad preferences and watch them for changes, so the touchscreen behaves like the trackpad.

- **Source:** the `com.apple.AppleMultitouchTrackpad` defaults domain, plus `-g` (global) keys. Values read on this Mac on 2026-10-09:

  | Key | Value | Meaning |
  |---|---|---|
  | `TrackpadThreeFingerDrag` | 1 | three-finger drag on (see item 4) |
  | `TrackpadFourFingerVertSwipeGesture` | 2 | four fingers up = Mission Control, down = App Exposé |
  | `TrackpadFourFingerHorizSwipeGesture` | 2 | four fingers left/right = switch Spaces |
  | `TrackpadFourFingerPinchGesture` / `TrackpadFiveFingerPinchGesture` | 2 | thumb + 3/4 fingers pinch = Launchpad, spread = Desktop |
  | `TrackpadTwoFingerFromRightEdgeSwipeGesture` | 3 | swipe left from the right edge = Notification Center |
  | `TrackpadPinch`, `TrackpadRotate`, `TrackpadMomentumScroll` | 1 | already supported |
  | `Clicking` | 1 | tap to click (already the touch default) |
  | `com.apple.swipescrolldirection` (`-g`) | unset (= natural) | scroll direction |
  | `AppleEnableSwipeNavigateWithScrolls` (`-g`) | unset (= on) | two-finger swipe between pages |
  | `com.apple.dock` `showMissionControlGestureEnabled` / `showAppExposeGestureEnabled` | 1 | Dock-side switches for the same gestures |

- **Watching for changes:**
  - Read the keys with `CFPreferencesCopyAppValue` after `CFPreferencesAppSynchronize`, because cfprefsd caches them.
  - Re-read when `~/Library/Preferences/com.apple.AppleMultitouchTrackpad.plist` changes (a DispatchSource file watcher; System Settings rewrites the file atomically, so re-arm the watcher after each change). Fall back to polling every 30 s.
  - Map each key to a gesture toggle; a value of 0 disables that gesture.

## 2. Four-finger gestures (done in v0.5.0)

Shipped as animated dock swipes (option 1 below), with Space switching left/right as well. Format and display rules: spec.md, implementation notes, "System gestures".

- Four fingers swipe up → Mission Control.
- Four fingers swipe down → App Exposé.
- **Recognizer:** a new state for gestures that start with 3–5 fingers landing within the two-finger window. Today 4+ fingers count as a palm and cancel the gesture. Keep palm rejection for 6+ fingers, or for contacts that land far apart in time.
- **Delivery options, most robust first:**
  1. Dock-swipe gesture events (event type 29/30, `kIOHIDEventTypeDockSwipe`), as in Mac Mouse Fix's `TouchSimulator.m`. Private, and the format changes across macOS versions.
  2. Simulate the keyboard shortcuts (Ctrl+↑ / Ctrl+↓).
  3. `open -b com.apple.exposelauncher`, Mission Control only.

## 3. Thumb pinch and spread (done in v0.5.0)

Shipped as the dock-swipe pinch (type 3; on macOS 15 it needs the "inverted" flag).

- Pinch with thumb + three/four fingers → Launchpad.
- Spread with thumb + three/four fingers → show Desktop.
- **Recognizer:** the spread of 4–5 contacts around their centroid shrinks or grows.
- **Delivery:** dock-swipe pinch events (Mac Mouse Fix uses type constant 4.2e-45 for pinch), or `open -a Launchpad`, or the Show Desktop shortcut (F11).
- **Note:** macOS 26 replaces Launchpad with the Apps view, so check the target version.

## 0. Three-finger drag: grab precision (revisit at the end)

Shipped in v0.3.0: three fingers moving together = click-and-drag, grabbing at the centre of the fingers or, by menu setting, under the first finger.

- **Owner feedback (2026-10-10):** "generally good but not perfect. The problem is mainly at the start: how to select the element that I want to drag."
- **Ideas:**
  - Show a small marker at the grab point while three fingers are down, so you can see what will be grabbed before moving.
  - Snap the grab to the draggable element nearest the fingers (Accessibility: text, file, title bar), instead of a geometric point.
  - Two-step: the first finger rests on the item, which fixes the grab point precisely; the next two fingers start the drag.
  - Grab under the finger that has moved least (the "anchor" finger) rather than the first or the centre.

## 4. Three-finger drag for click-and-drag (done in v0.3.0, see 0)

This would make click-and-drag available with one-finger scroll on and no hold needed: three fingers move = left-button drag, like the trackpad setting.

- Deliver as a mouse drag (Warp, like hold-drag) from the centroid of the three fingers.
- Follow `TrackpadThreeFingerDrag`.

## 5. Two-finger swipe left/right = back/forward (investigated 2026-10-10, parked)

Safari navigates from trackpad two-finger swipes. Our synthesized horizontal scrolls scroll the page but don't navigate.

- **Found, with the Event Sink's swipe-tracking probe** (`trackSwipeEvent`, as Safari and WebKit do):
  - AppKit **starts** swipe tracking for our scrolls and receives every changed event.
  - It never computes progress from them: trackpad 0 → 0.77 → complete; ours stuck at 0.00, then cancelled.
- **Ruled out with `--direct-selftest --swipe` (variants S1–S11):**
  - fields 175/177 (accelerated and raw horizontal deltas, realistic values);
  - 137 (the direction-inverted flag; confirmed: it sets `isDirectionInvertedFromDevice`);
  - 87 (sender id);
  - 126 (underlying HID event type, raw bits 6 = kIOHIDEventTypeScroll);
  - 169 (HID timestamp);
  - 101 = 60;
  - 119/139 (gesture phase, raw bits 1 began / 2 changed / 4 ended, which the trackpad updates per event and CGEventCreateScrollWheelEvent2 leaves at 1).
- **Likely cause:** AppKit reads swipe progress from the IOHIDEvent attached to real trackpad events. Synthetic CGEvents carry none.
- **Options when resumed:**
  1. **Interactive:** attach a synthetic IOHIDEvent (IOHIDEventCreateScrollEvent + CGEventSetHIDEvent, both private; Mac Mouse Fix uses CGEventSetHIDEvent for dock swipes on new macOS).
  2. **Pragmatic:** a fast horizontal two-finger flick posts the NavigationSwipe gesture event (type 29, subtype 16), falling back to ⌘[ / ⌘]. No page-slide animation.

## 6. Swipe left from the right edge = Notification Center (done in v0.5.0)

- **Recognizer:** two fingers that start within 15 mm of the panel's right edge and move mostly left for 10 mm. They may move unevenly: the first rule (5 mm zone, fingers moving together) missed most of the owner's attempts, which the log showed as rotate or scroll.
- **Delivery:** no dock swipe exists for it. Accessibility "press" on the menu-bar clock when the touch display has the active menu bar; otherwise a Warp click on the touch display's own clock (v0.5.1).

## 7. Raw multitouch for painting apps and games

The pipeline already tracks up to 10 fingers and exposes them (`InputPipeline.onContacts`). macOS has no public way to give apps raw multi-finger touches, so a painting or game mode would need either:
- a TouchBridge-aware app (send the contacts over XPC or a local socket), or
- a per-app mapping of touches to mouse/keyboard input.

## Window dragging (improved 2026-10-09, needs owner's feel test)

- **Owner report:** dragging windows by the title bar "works but feels a little counter-intuitive".
- **Cause:** the log showed drags 28–43 pt below Safari's top edge routed as normal drags or scrolls. The fixed 28 pt title band covered only half of Safari's roughly 50 pt toolbar.
- **Change:** the draggable area now comes from the Accessibility API (`WindowDragRules`, `--ax-probe --map`).
- **If it still feels off,** candidates are:
  1. no 3 mm pan slop before a window drag starts;
  2. starting the Warp drag at touch-down instead of at classification time.
