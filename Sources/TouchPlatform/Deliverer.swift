import AppKit
import CoreGraphics
import TouchCore

/// Everything the deliverer does to the outside world, so tests can watch it.
protocol DeliveryEffects: AnyObject {
    func post(_ event: CGEvent, to target: Deliverer.Target)
    func cursorLocation() -> CGPoint?
    func warpCursor(to point: CGPoint)
    func reassociateCursor()
    func hideCursor()
    func showCursor()
    func frontmostApp() -> pid_t?
    func activate(_ pid: pid_t)
    func recordPress(pid: Int32, right: Bool)
    func clearPress()
    func pendingPress() -> (pid: Int32, right: Bool)?
}

/// The real effects: window server, cursor, app activation, press journal on disk.
final class SystemDeliveryEffects: DeliveryEffects {
    private let journal = PressJournal()

    init() { CursorVisibility.allowHidingInBackground() }

    func post(_ event: CGEvent, to target: Deliverer.Target) {
        switch target {
        case let .direct(direct): direct.post(event)
        case .warp: event.post(tap: .cghidEventTap)
        }
    }
    func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }
    func warpCursor(to point: CGPoint) { CGWarpMouseCursorPosition(point) }
    func reassociateCursor() { CGAssociateMouseAndMouseCursorPosition(1) }
    func hideCursor() { CursorVisibility.hide() }
    func showCursor() { CursorVisibility.show() }
    func frontmostApp() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func activate(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.activate() }
    func recordPress(pid: Int32, right: Bool) { journal.record(pid: pid, right: right) }
    func clearPress() { journal.clear() }
    func pendingPress() -> (pid: Int32, right: Bool)? { journal.pending() }
}

/// Posts one gesture at a time, either straight to the target app (Direct) or through the
/// window server with the cursor briefly moved there (Warp). Runs on the pipeline queue.
final class Deliverer {
    enum Target: Equatable {
        case direct(DirectTarget)
        case warp
    }

    var dryRun = false
    var focusMode: FocusMode = .followTouch
    /// Trackpad setting "momentum scrolling".
    var momentumEnabled = true
    var log: (String) -> Void = { _ in }

    private let queue: DispatchQueue
    private let effects: DeliveryEffects
    private let directSource = CGEventSource(stateID: .privateState)
    private let warpSource = CGEventSource(stateID: .hidSystemState)
    private var target: Target = .warp
    private var location = CGPoint.zero
    private var eventNumber: Int64 = 0
    private var buttonDown: CGMouseButton?
    /// The scroll/pinch/rotate phase an app has been told began and not yet told ended.
    private var openPhase: OpenPhase?
    private enum OpenPhase { case scroll, magnify, rotate }
    /// Warp has the cursor hidden and parked at a finger; `savedCursor` is where it came from.
    private var parked = false
    private var savedCursor: CGPoint?
    private var restore: DispatchWorkItem?
    private var momentumTimer: DispatchSourceTimer?
    /// The app that was frontmost before touches activated another one (for "return focus").
    private var previousFrontmost: pid_t?
    private var focusReturn: DispatchWorkItem?

    /// How long the cursor stays at the finger after a Warp gesture before returning.
    static let warpReturnDelay: TimeInterval = 0.05
    /// Longer than the double-click interval, so a double-tap doesn't bounce focus back and forth.
    static let focusReturnDelay: TimeInterval = 0.6

    init(queue: DispatchQueue, effects: DeliveryEffects = SystemDeliveryEffects()) {
        self.queue = queue
        self.effects = effects
    }

    // MARK: gesture lifecycle

    /// `appPID` is the app owning the touched window; `activate` asks for it to be made active first
    /// (macOS swallows clicks and drops pinches aimed at a background app's window).
    func begin(_ target: Target, at point: CGPoint, appPID: pid_t?, activate: Bool) {
        stopMomentum()
        self.target = target
        location = point
        eventNumber += 1
        log("begin \(target) at \(Int(point.x)),\(Int(point.y))")
        focusReturn?.cancel()
        focusReturn = nil
        if activate, let appPID, !dryRun {
            let frontmost = effects.frontmostApp()
            if frontmost != appPID {
                if previousFrontmost == nil { previousFrontmost = frontmost }
                // A Warp click is routed by the window server, which activates the app by itself.
                if case .direct = target { effects.activate(appPID) }
            }
        }
        restore?.cancel()
        restore = nil
        guard target == .warp, !dryRun else {
            // A Direct gesture right after a Warp one (or its momentum) gives the cursor back now.
            returnCursor()
            return
        }
        if !parked {
            savedCursor = effects.cursorLocation()
            effects.hideCursor()
            parked = true
        }
        effects.warpCursor(to: point)
    }

    /// `returnDelay`: how long a parked cursor stays at the finger (longer for system gestures, which
    /// pick their display from the cursor while their animation starts).
    func end(returnDelay: TimeInterval = Deliverer.warpReturnDelay) {
        scheduleFocusReturn()
        guard parked else { return }
        let work = DispatchWorkItem { [weak self] in self?.returnCursor() }
        restore = work
        queue.asyncAfter(deadline: .now() + returnDelay, execute: work)
    }

    private func scheduleFocusReturn() {
        guard focusMode == .returnToPrevious, let previous = previousFrontmost else {
            previousFrontmost = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.effects.activate(previous)
            self?.previousFrontmost = nil
            self?.focusReturn = nil
        }
        focusReturn = work
        queue.asyncAfter(deadline: .now() + Self.focusReturnDelay, execute: work)
    }

    // MARK: clicks and drags

    func click(at point: CGPoint, count: Int, button: CGMouseButton) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        press(down, at: point, button: button, clickState: count)
        release(up, at: point, button: button, clickState: count)
    }

    func dragDown(at point: CGPoint) {
        press(.leftMouseDown, at: point, button: .left, clickState: 1)
    }

    func dragMove(to point: CGPoint) {
        post(EventSynth.mouse(.leftMouseDragged, at: point, button: .left, clickState: 1, eventNumber: eventNumber, window: window, source: source))
    }

    func dragUp(at point: CGPoint) {
        release(.leftMouseUp, at: point, button: .left, clickState: 1)
    }

    /// A mouse-moved event with a push direction, through the window server. It moves the parked cursor,
    /// and pushes against a display edge (the Dock moves to a display when the cursor pushes against its
    /// bottom edge).
    func nudge(at point: CGPoint, dx: Int64, dy: Int64) {
        guard let event = CGEvent(mouseEventSource: warpSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        guard !dryRun else { return }
        effects.post(event, to: .warp)
    }

    /// Sends the missing mouse-up if a press is still open (quit, disable, crash recovery).
    func releaseStuckPress() {
        if let button = buttonDown {
            let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
            release(up, at: location, button: button, clickState: 1)
        }
        if let pending = effects.pendingPress() {
            let up: CGEventType = pending.right ? .rightMouseUp : .leftMouseUp
            if let event = EventSynth.mouse(up, at: effects.cursorLocation() ?? .zero, button: pending.right ? .right : .left,
                                            clickState: 1, eventNumber: 0, window: nil, source: directSource) {
                if pending.pid > 0 { event.postToPid(pending.pid) } else { effects.post(event, to: .warp) }
            }
            log("released a press left open by a previous run (pid \(pending.pid))")
            effects.clearPress()
        }
        returnCursor()
    }

    /// Closes whatever is open (momentum, scroll/pinch/rotate phase, pressed button) and gives the
    /// cursor back. For Disable, Quit, and the touch display disappearing mid-gesture.
    func abortGesture() {
        stopMomentum()
        if let phase = openPhase {
            switch phase {
            case .scroll: post(EventSynth.scroll(dx: 0, dy: 0, at: location, phase: .ended, momentum: .none, window: window, source: source))
            case .magnify: post(EventSynth.magnify(0, at: location, phase: .ended, window: window, source: source))
            case .rotate: post(EventSynth.rotate(0, at: location, phase: .ended, window: window, source: source))
            }
            openPhase = nil
        }
        if let button = buttonDown {
            release(button == .right ? .rightMouseUp : .leftMouseUp, at: location, button: button, clickState: 1)
        }
        focusReturn?.cancel()
        focusReturn = nil
        previousFrontmost = nil
        restore?.cancel()
        returnCursor()
    }

    // MARK: scroll and gestures

    func scroll(dx: Double, dy: Double, phase: GesturePhase) {
        post(EventSynth.scroll(dx: dx, dy: dy, at: location, phase: synthPhase(phase), momentum: .none, window: window, source: source))
        openPhase = phase == .ended ? nil : .scroll
    }

    /// Ends the finger phase, then plays momentum (points per second) and finishes the gesture.
    func scrollEnded(velocityX: Double, velocityY: Double) {
        post(EventSynth.scroll(dx: 0, dy: 0, at: location, phase: .ended, momentum: .none, window: window, source: source))
        openPhase = nil
        var momentum = Momentum(velocityX: velocityX, velocityY: velocityY)
        guard momentumEnabled, let first = momentum.next() else { end(); return }
        post(EventSynth.scroll(dx: first.dx, dy: first.dy, at: location, phase: nil, momentum: .begin, window: window, source: source))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0 / 120, repeating: 1.0 / 120)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let step = momentum.next() {
                post(EventSynth.scroll(dx: step.dx, dy: step.dy, at: location, phase: nil, momentum: .continue, window: window, source: source))
            } else {
                stopMomentum()
                end()
            }
        }
        momentumTimer = timer
        timer.resume()
    }

    func magnify(_ delta: Double, phase: GesturePhase) {
        post(EventSynth.magnify(delta, at: location, phase: synthPhase(phase), window: window, source: source))
        openPhase = phase == .ended ? nil : .magnify
        if phase == .ended { end() }
    }

    func rotate(_ degrees: Double, phase: GesturePhase) {
        post(EventSynth.rotate(degrees, at: location, phase: synthPhase(phase), window: window, source: source))
        openPhase = phase == .ended ? nil : .rotate
        if phase == .ended { end() }
    }

    // MARK: internals

    private var window: Int? {
        if case let .direct(direct) = target { direct.window } else { nil }
    }

    private var source: CGEventSource? {
        target == .warp ? warpSource : directSource
    }

    private func press(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int) {
        buttonDown = button
        if case let .direct(direct) = target { effects.recordPress(pid: direct.pid, right: button == .right) } else { effects.recordPress(pid: 0, right: button == .right) }
        post(EventSynth.mouse(type, at: point, button: button, clickState: clickState, eventNumber: eventNumber, window: window, source: source))
    }

    private func release(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int) {
        post(EventSynth.mouse(type, at: point, button: button, clickState: clickState, eventNumber: eventNumber, window: window, source: source))
        buttonDown = nil
        effects.clearPress()
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        if dryRun {
            log("dry-run \(event.type.rawValue) at \(Int(event.location.x)),\(Int(event.location.y)) → \(target)")
            return
        }
        effects.post(event, to: target)
    }

    private func stopMomentum() {
        guard let timer = momentumTimer else { return }
        timer.cancel()
        momentumTimer = nil
        post(EventSynth.scroll(dx: 0, dy: 0, at: location, phase: nil, momentum: .end, window: window, source: source))
    }

    private func returnCursor() {
        restore = nil
        guard parked else { return }
        if let saved = savedCursor {
            effects.warpCursor(to: saved)
            effects.reassociateCursor()
        }
        effects.showCursor()   // even if the original position was unknown
        savedCursor = nil
        parked = false
    }

    private func synthPhase(_ phase: GesturePhase) -> EventSynth.Phase {
        switch phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        }
    }
}

/// Remembers an open press on disk so a crash can't leave a mouse button held down.
final class PressJournal {
    private let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/TouchBridge/press.json")

    func record(pid: Int32, right: Bool) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["pid": pid, "right": right]).write(to: url)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    func pending() -> (pid: Int32, right: Bool)? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32 else { return nil }
        return (pid, object["right"] as? Bool ?? false)
    }
}

/// Hides the cursor while TouchBridge is in the background, via a private CoreGraphics call looked up at runtime.
/// If the call is missing, the cursor simply stays visible during Warp gestures.
enum CursorVisibility {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    nonisolated(unsafe) private static var hidden = false
    nonisolated(unsafe) private static var available = false

    static func allowHidingInBackground() {
        guard let connSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
              let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSym, to: SetProperty.self)
        available = set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }

    static func hide() {
        guard available, !hidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}
