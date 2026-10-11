import AppKit
import ApplicationServices
import TouchCore

/// `--system-ui-selftest`: which display do Notification Center and Launchpad open on, for each way of
/// triggering them? Tries each variant, reads back where their windows appeared, and closes them again.
///
/// VISIBLE on screen (opens and closes Notification Center and Launchpad): run only with the owner
/// watching. `--nc` or `--launchpad` runs one half. `--move-dock` adds a variant that moves the Dock to the
/// touch display, opens Launchpad, and moves the Dock back.
public enum SystemUISelfTest {
    public static func run(log: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { log("needs Accessibility; stopping"); return }
        guard let touch = SystemDisplays.online().first(where: { CGDisplayVendorNumber($0) == 7908 && CGDisplayModelNumber($0) == 342 }) else {
            log("touch display not found; stopping")
            return
        }
        CursorVisibility.allowHidingInBackground()
        let test = Session(touchID: touch, log: log)
        let args = CommandLine.arguments
        let all = !args.contains("--nc") && !args.contains("--launchpad")
        log("start: \(test.state())")
        if all || args.contains("--nc") { test.notificationCenter() }
        if all || args.contains("--launchpad") { test.launchpad(moveDock: args.contains("--move-dock")) }
        test.returnCursor()
        log("done: \(test.state())")
    }
}

private final class Session {
    let touch: ScreenRect
    let touchUUID: String?
    let log: (String) -> Void
    let swipe = DockSwipe(queue: DispatchQueue(label: "systemui-selftest"))
    let source = CGEventSource(stateID: .hidSystemState)
    /// Where the cursor was at the start; every variant puts it back here.
    let home: CGPoint
    var hidden = false

    init(touchID: CGDirectDisplayID, log: @escaping (String) -> Void) {
        touch = SystemDisplays.rect(touchID)
        touchUUID = SystemDisplays.uuid(touchID)
        self.log = log
        home = CGEvent(source: nil)?.location ?? .zero
    }

    var touchCentre: CGPoint { CGPoint(x: touch.x + touch.width / 2, y: touch.y + touch.height / 2) }

    // MARK: Notification Center

    func notificationCenter() {
        closeNotificationCenter()   // start from a closed panel
        // Presses first, while the active menu bar is still where the owner works (clicks on the touch
        // display's clock move it there): this separates "follows the cursor" from "follows the menu bar".
        nc("nc-1 press the active clock, cursor untouched (v0.5.0)") {
            guard let clock = NotificationCenterOpener.clock() else { return false }
            return NotificationCenterOpener.press(clock)
        }
        nc("nc-2 press the active clock, cursor held on the touch display 1 s") {
            guard let clock = NotificationCenterOpener.clock() else { return false }
            self.park(at: self.touchCentre)
            return NotificationCenterOpener.press(clock)
        }
        nc("nc-3 press the active clock, cursor moved (with events) onto the touch display and held 1 s") {
            guard let clock = NotificationCenterOpener.clock() else { return false }
            self.park(at: self.touchCentre, withMoves: true)
            return NotificationCenterOpener.press(clock)
        }
        nc("nc-4 click the touch display's clock, cursor back after 50 ms (v0.5.1)") {
            guard let p = self.touchClock() else { return false }
            self.park(at: p)
            self.click(at: p)
            Thread.sleep(forTimeInterval: 0.05)
            self.returnCursor()
            return true
        }
        nc("nc-5 click the touch display's clock, cursor held there 1 s") {
            guard let p = self.touchClock() else { return false }
            self.park(at: p)
            self.click(at: p)
            return true
        }
    }

    private func nc(_ name: String, trigger: () -> Bool) {
        log("\(name): \(state())")
        let triggered = trigger()
        Thread.sleep(forTimeInterval: 1.0)
        log("  → \(triggered ? "" : "trigger failed; ")Notification Center on \(notificationCenterDisplay())")
        returnCursor()
        closeNotificationCenter()
    }

    /// Toggles the panel shut through the active clock, then through the clock on the panel's display.
    private func closeNotificationCenter() {
        guard notificationCenterDisplay() != "closed" else { return }
        if let clock = NotificationCenterOpener.clock() { _ = NotificationCenterOpener.press(clock) }
        Thread.sleep(forTimeInterval: 0.8)
        if notificationCenterDisplay() == "touch display", let p = touchClock() {
            park(at: p)
            click(at: p)
            Thread.sleep(forTimeInterval: 0.3)
            returnCursor()
            Thread.sleep(forTimeInterval: 0.8)
        }
        let now = notificationCenterDisplay()
        log(now == "closed" ? "  closed" : "  still open on \(now): please close it")
    }

    /// The touch display's own clock, only if a ControlCenter status item is visible there.
    private func touchClock() -> CGPoint? {
        guard let clock = NotificationCenterOpener.clock() else { log("  no clock"); return nil }
        let centre = ScreenPoint(x: clock.frame.midX, y: clock.frame.midY)
        guard let source = SystemDisplays.online().map(SystemDisplays.rect).first(where: { $0.contains(centre) }) else { return nil }
        let p = MenuBarGeometry.sameStatusItem(as: centre, on: source, in: touch)
        guard WindowHitTester.topWindow(at: p, in: WindowLocator.onScreenWindows(), excludingPID: -1)?.pid == clock.pid else {
            log("  touch display's clock not visible")
            return nil
        }
        return CGPoint(x: p.x, y: p.y)
    }

    private func notificationCenterDisplay() -> String {
        let panels = NotificationCenterOpener.openPanels()
        return panels.isEmpty ? "closed" : panels.map { displayName(centreOf: $0) }.joined(separator: " + ")
    }

    // MARK: Launchpad

    func launchpad(moveDock: Bool) {
        closeLaunchpad()
        lp("lp-1 pinch, cursor held on the touch display (v0.5.1)") {
            self.park(at: self.touchCentre)
            self.pinch(in: true)
        }
        lp("lp-2 pinch, cursor moved (with events) onto the touch display and held") {
            self.park(at: self.touchCentre, withMoves: true)
            self.pinch(in: true)
        }
        lp("lp-3 open Launchpad.app, cursor moved (with events) onto the touch display and held") {
            self.park(at: self.touchCentre, withMoves: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
        }
        guard moveDock else { return }
        let dockWasOn = dockDisplay()
        pushDock(to: touch)
        lp("lp-4 pinch with the Dock moved to the touch display, cursor held there") {
            self.park(at: self.touchCentre)
            self.pinch(in: true)
        }
        if dockWasOn == "other display", let other = SystemDisplays.online().map(SystemDisplays.rect).first(where: { $0 != touch }) {
            pushDock(to: other)
        }
        returnCursor()
    }

    private func lp(_ name: String, trigger: () -> Void) {
        log("\(name): \(state())")
        trigger()
        Thread.sleep(forTimeInterval: 1.2)
        log("  → Launchpad on \(launchpadDisplay())")
        returnCursor()
        closeLaunchpad()
    }

    /// Pinching out closes an open Launchpad (and would show the desktop if none were open, so only then).
    private func closeLaunchpad() {
        guard launchpadDisplay() != "closed" else { return }
        pinch(in: false)
        Thread.sleep(forTimeInterval: 1.2)
        let now = launchpadDisplay()
        log(now == "closed" ? "  closed" : "  still open on \(now): please close it (Esc)")
    }

    /// The thumb-pinch dock swipe as the pipeline sends it (inverted flag on macOS 15).
    private func pinch(in inward: Bool) {
        let d = inward ? 0.05 : -0.05   // inward (positive) opens Launchpad, outward closes it
        swipe.post(delta: d, kind: .pinch, phase: .began, inverted: true)
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.016)
            swipe.post(delta: d, kind: .pinch, phase: .changed, inverted: true)
        }
        Thread.sleep(forTimeInterval: 0.016)
        swipe.post(delta: d, kind: .pinch, phase: .ended, inverted: true)
    }

    private func launchpadDisplay() -> String {
        let windows = DockLocator.launchpadWindows()
        return windows.isEmpty ? "closed" : windows.map { displayName(centreOf: $0) }.joined(separator: " + ")
    }

    /// The Dock moves to a display when the cursor pushes against that display's bottom edge.
    private func pushDock(to display: ScreenRect) {
        let p = CGPoint(x: display.x + display.width / 2, y: display.y + display.height - 1)
        park(at: p)
        for _ in 0..<40 {
            let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventDeltaY, value: 4)
            e?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.015)
        }
        Thread.sleep(forTimeInterval: 0.8)
        log("pushed the Dock towards \(displayName(centreOf: display)): Dock now on \(dockDisplay())")
    }

    // MARK: cursor and state

    private func park(at p: CGPoint, withMoves: Bool = false) {
        if !hidden { CursorVisibility.hide(); hidden = true }
        CGWarpMouseCursorPosition(p)
        guard withMoves else { return }
        for i in 0..<5 {
            let at = CGPoint(x: p.x + Double(i), y: p.y)
            let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventDeltaX, value: 1)
            e?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func returnCursor() {
        guard hidden else { return }
        CGWarpMouseCursorPosition(home)
        CGAssociateMouseAndMouseCursorPosition(1)
        CursorVisibility.show()
        hidden = false
    }

    private func click(at p: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func state() -> String {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let bar = SystemDisplays.activeMenuBarDisplayUUID()
        let barName = bar == nil ? "unknown" : (bar == touchUUID ? "touch display" : "other display")
        return "cursor on \(displayName(ScreenPoint(x: cursor.x, y: cursor.y))), active menu bar on \(barName), Dock on \(dockDisplay())"
    }

    private func dockDisplay() -> String {
        DockLocator.anchor().map(displayName) ?? "unknown"
    }

    private func displayName(centreOf r: ScreenRect) -> String {
        displayName(ScreenPoint(x: r.x + r.width / 2, y: r.y + r.height / 2))
    }

    private func displayName(_ p: ScreenPoint) -> String {
        if touch.contains(p) { return "touch display" }
        return SystemDisplays.online().map(SystemDisplays.rect).contains { $0.contains(p) } ? "other display" : "no display"
    }
}
