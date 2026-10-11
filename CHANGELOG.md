# Changelog

## 1.1.0 (2026-10-11)

- **Touch Mode menu** (✋ → Touch Mode). It resets to Gestures at each start, and the menu-bar icon shows a special mode.
  - **Drawing** (✏️): the first finger is a pen, from touch-down to lift. Every other finger, a resting palm and every gesture are ignored. Strokes go through the window server, so drawing apps and websites see a real mouse press.
  - **Multitouch Apps** (🖐): every finger, up to ten, as TUIO 1.1 over UDP to `127.0.0.1:3333`, for TUIO apps such as TouchDesigner, Processing, openFrameworks, Unity, Max or Kivy. Nothing is delivered to macOS in this mode.
- **Event Sink as a multitouch test canvas:** it reads TUIO and paints every finger in its own colour, plus the mouse stroke in grey, with a live finger count and a Clear button.
- The README explains what macOS allows: ordinary apps, web pages and iPhone/iPad apps get a single pointer, so more fingers reach only apps that read a multitouch protocol such as TUIO.

## 1.0.0 (2026-10-11)

The first stable release. On the tested setup (an ARZOPA touch monitor with an ILITEK controller, macOS 15), the touch display behaves like a touchscreen with a trackpad built in:

- Touches land on the touch display, and for most gestures the cursor stays where it is.
- **Gestures:**
  - tap, double and triple tap, right-click (hold);
  - scrolling with momentum, pinch, rotate;
  - click-and-drag, three-finger drag, window moves by the title bar.
- **The trackpad's system gestures with the system's own animations**, opening on the touch display: Mission Control, App Exposé, Spaces, Launchpad, Show Desktop and Notification Center.
- **Back/forward page swipes** that follow your fingers, in Safari and other apps with trackpad page swipes.
- **Follows the trackpad settings** in System Settings.
- **Daily reliability:**
  - starts at login and restarts after a crash;
  - recovers after replug and sleep;
  - crash-safe mouse presses.
- README for newcomers, MIT license. The replay recording now ships with the repo, so a fresh clone runs all tests.

No functional changes since 0.6.4.

## 0.6.4

- The menu lists the followed trackpad settings one per line, instead of one long line that made the menu too wide.

## 0.6.3

- **Crash-safe press recovery.** The press journal records where a press was made and, for presses sent straight to an app, the window and the app. After a crash, the restarted app releases the press there:
  - an interrupted drag drops back where it started;
  - a reused process ID never receives the release.

## 0.6.2

- **Real trackpad page swipes.** Two-finger scrolls now carry the scroll-gesture stream a real trackpad sends: type-29 gesture events, subtype 61, then 6 for each movement, then 62. AppKit's swipe tracking measures progress from that stream, so Safari's back/forward swipe follows the fingers and completes or snaps back natively.
- The stream was found by tapping all events sent to a test window's process, because the swipe tracker takes them before any app-level monitor sees them.
- 0.6.0 and 0.6.1 were prototypes: a quick flick sent ⌘[ / ⌘], then pressed the app's Back/Forward menu item instead. Both were replaced by the real swipe.

## 0.5.10

- **Three-finger drag, "rest a finger, add two".** Rest one finger on an item, add two more within 1.5 s, and move. The drag grabs exactly where the resting finger first touched.

## 0.5.8

- A Space switch on the touch display follows the hidden cursor alone; the earlier step of focusing a window first was removed.
- **Keep Focus When Switching Spaces** (on by default) gives focus back to the app on the other screen after a Space switch by touch.

## 0.5.5

- **System gestures with the system's own animations**, via synthesized dock-swipe events:
  - four fingers up / down: Mission Control / App Exposé;
  - four fingers left / right: switch Space;
  - thumb pinch / spread: Launchpad / Show Desktop.
- Two fingers from the right edge open Notification Center.
- **All of them open on the touch display:**
  - Notification Center and Spaces follow the cursor, so the hidden cursor waits on the touch display while they open;
  - Launchpad follows the Dock, so the Dock is brought over first.
- Menu "Launchpad on the Touch Display" chooses whether the Dock comes over, comes over then goes back, or stays put.
- Diagnostics: `--dockswipe-selftest`, `--ax-probe --menubar`, `--system-ui-selftest`.

## 0.4.0

- **Follows the trackpad settings** in System Settings → Trackpad: three-finger drag, scrolling, momentum, pinch and rotate. Changes are picked up within seconds and after wake. A "Follow Trackpad Settings" master switch controls this.

## 0.3.0

- **Three-finger drag**, like the trackpad setting, grabbing at the centre of the fingers or under the first finger.
- Menu settings survive restarts.

## 0.2.0

- **Start at Login**: a per-user launch agent that starts TouchBridge at login and restarts it after a crash.
- `scripts/install.sh` installs and updates the copy in `~/Applications`.
- **Multitouch after replug and sleep.** The panel then starts in single-touch "mouse" mode; TouchBridge reads its feature reports to switch it back, as Linux's hid-multitouch driver does.

## 0.1.0

- **First version.** A user-space driver that seizes the touch panel and delivers touches to the touch display without moving the cursor.
- **Delivery:**
  - Direct: events posted to the app under the finger with window addressing, and the app activated before clicks;
  - Warp: a fallback for window moves, the Dock and menu bar, pop-up menus and Chromium apps.
- **Gestures:** tap, double and triple tap, right-click, scrolling with momentum, pinch, rotate, click-and-drag, window moves.
- Menu-bar agent with diagnostics.
