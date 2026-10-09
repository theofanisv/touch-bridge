# TouchBridge backlog

Requested by the owner on 2026-10-09, for later. Nothing here is implemented yet.

## 1. Follow the Mac's trackpad settings

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

## 2. Four-finger gestures

- Four fingers swipe up → Mission Control.
- Four fingers swipe down → App Exposé.
- **Recognizer:** a new state for gestures that start with 3–5 fingers landing within the two-finger window. Today 4+ fingers count as a palm and cancel the gesture. Keep palm rejection for 6+ fingers, or for contacts that land far apart in time.
- **Delivery options, most robust first:**
  1. Dock-swipe gesture events (event type 29/30, `kIOHIDEventTypeDockSwipe`), as in Mac Mouse Fix's `TouchSimulator.m`. Private, and the format changes across macOS versions.
  2. Simulate the keyboard shortcuts (Ctrl+↑ / Ctrl+↓).
  3. `open -b com.apple.exposelauncher`, Mission Control only.

## 3. Thumb pinch and spread

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

## 5. Two-finger swipe left/right = back/forward

Safari already navigates from trackpad two-finger swipes. Our synthesized horizontal scrolls scroll the page but don't navigate.

- **Hypothesis:** AppKit's swipe tracking (`trackSwipeEvent`, enabled by `AppleEnableSwipeNavigateWithScrolls`) also needs gesture-phase context from a real trackpad: the scroll events' gesture/phase bookkeeping, a `mayBegin` phase, `isDirectionInvertedFromDevice`, or the accompanying gesture-begin event (type 29 with phase).
- **Next step:** diff a real trackpad horizontal swipe against ours in the Event Sink (log every field, as was done for the Direct window fields).
- **Fallback:** recognize a fast horizontal two-finger flick and post the NavigationSwipe gesture (type 29, subtype 16), or send Cmd+[ / Cmd+].

## 6. Swipe left from the right edge = Notification Center

- **Recognizer:** two fingers that start within about 5 mm of the panel's right edge and move left.
- **Delivery:** the dock-swipe gesture for Notification Center if available. Otherwise click the menu-bar clock through Warp: on macOS 15 that opens Notification Center.

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
