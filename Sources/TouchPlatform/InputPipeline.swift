import AppKit
import CoreGraphics
import TouchCore

/// Live settings, changed from the menu. Applied on the pipeline queue.
public struct PipelineSettings: Sendable {
    public var policy = DeliveryPolicy()
    public var dryRun = false
    /// Bundle identifier → forced delivery mode.
    public var appOverrides: [String: DeliveryMode] = [:]
    /// The touch display's EDID identity (defaults: the ARZOPA on this Mac).
    public var focus: FocusMode = .followTouch
    public var oneFingerDrag: OneFingerDragMode = .scroll
    public var threeFingerDrag = true
    public var threeFingerAnchor: ThreeFingerAnchor = .centroid
    /// When set, the trackpad's settings decide three-finger drag, scroll, pinch, rotate and momentum.
    public var trackpad: TrackpadPreferences?
    /// Launchpad opens on the display with the Dock: whether a pinch-in on the touch display brings it over.
    public var launchpadDock: LaunchpadDockMode = .bringDockAndReturn
    /// After a Space switch on the touch display macOS moves focus there; when on, focus that was on another
    /// display is given back (`FocusKeeper`).
    public var keepFocusOnSpaceSwitch = true
    public var displayVendor: UInt32 = 7908
    public var displayModel: UInt32 = 342

    public init() {}
}

/// HID reports → contacts → gestures → Direct/Warp delivery onto the touch display.
public final class InputPipeline: @unchecked Sendable {
    public var onStatus: (@Sendable (String) -> Void)?
    /// Every finger on the panel (up to 10) after each frame, in panel coordinates. Runs on the HID queue.
    /// Unused today; the hook for a future painting/game mode (see docs/backlog.md).
    public var onContacts: (@Sendable ([UInt8: PanelPoint]) -> Void)?
    /// Called when the number of fingers changes: (now, most seen since start). Runs on the HID queue.
    public var onTouchCount: (@Sendable (Int, Int) -> Void)?

    private let source = HIDTouchSource()
    private var queue: DispatchQueue { source.queue }
    private lazy var deliverer = Deliverer(queue: queue)
    private lazy var dockSwipe = DockSwipe(queue: queue)
    private let apps = AppDirectory()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // Everything below is only touched on `queue`.
    private var settings = PipelineSettings()
    private var tracker = ContactTracker()
    private var recognizer = GestureRecognizer()
    private var contacts: [UInt8: PanelPoint] = [:]
    private var mapper: CoordinateMapper?
    private var expireTimer: DispatchSourceTimer?
    private var gestureStart: CGPoint?
    private var touchCount = 0
    private var maxTouchCount = 0
    private var panelMode = PanelModeWatch()
    /// The window-drag answer for the gesture being classified, so Accessibility is asked once.
    private var windowDragMemo: (point: CGPoint, result: Bool)?
    /// The touch display's UUID, as the window server names displays in its Space state.
    private var touchDisplayUUID: String?
    /// The dock swipe between its `began` and `ended`/`cancelled`.
    private var openDockSwipe: DockSwipeKind?
    private var swipeHold = DockSwipeHold()
    private var spacesAtSwipeStart: [(String, UInt64)] = []
    /// This pinch parked the cursor to bring the Dock over (so its end gives the cursor back).
    private var dockBroughtForPinch = false
    /// A push of the hidden cursor against a bottom edge, moving the Dock; nil when none is running.
    private var dockPush: (generation: Int, back: Bool)?
    private var dockPushGeneration = 0
    /// "Bring the Dock over, then back": where the Dock came from, and the watch that says when to return it.
    private var dockReturn: (watch: DockReturnWatch, home: ScreenRect)?
    private var dockReturnTimer: DispatchSourceTimer?
    /// Between start() and stop(): only a running pipeline moves the Dock.
    private var running = false
    /// The app that had focus on another display when a Space switch began on the touch display.
    private var focusBeforeSwitch: pid_t?
    /// Watching for macOS to move focus after that switch; a new touch cancels it.
    private var focusKeeper: (keeper: FocusKeeper, generation: Int)?
    private var focusKeeperGeneration = 0

    /// How long the hidden cursor stays on the touch display after a Space switch ends or Notification Center
    /// is opened: past the dock swipe's re-sent end events (0.5 s), so the system has picked its display.
    static let systemGestureCursorDelay: TimeInterval = 0.8
    /// Longest push against a bottom edge before giving up on moving the Dock.
    static let dockPushTimeoutMs = 1500.0

    public init() {}

    public func update(_ change: @escaping @Sendable (inout PipelineSettings) -> Void) {
        queue.async { [self] in
            change(&settings)
            deliverer.dryRun = settings.dryRun
            dockSwipe.dryRun = settings.dryRun
            deliverer.focusMode = settings.focus
            applyGestureSettings(to: &recognizer)
            refreshDisplay()
        }
    }

    /// "Then back" chosen in the menu (even if it already was): a Dock found on the touch display goes home.
    public func returnDockHome() {
        queue.async { [self] in
            guard running, settings.launchpadDock == .bringDockAndReturn else { return }
            sendDockHomeIfOnTouchDisplay()
        }
    }

    public func start() {
        source.onStatus = { [weak self] in self?.status($0) }
        source.onReport = { [weak self] timestamp, bytes in self?.handle(report: bytes, timestamp: timestamp) }
        queue.async { [self] in
            resetGestureState()
            deliverer.log = { [weak self] in self?.status($0) }
            dockSwipe.log = { [weak self] in self?.status($0) }
            dockSwipe.dryRun = settings.dryRun
            deliverer.dryRun = settings.dryRun
            deliverer.releaseStuckPress()
            mapper = nil  // so the display line is reported even if settings changed before start
            refreshDisplay()
            startExpiryTimer()
            running = true
        }
        CGDisplayRegisterReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        source.start()
    }

    public func stop() {
        CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        source.stop()   // first, so no frame can open a new gesture while we close the current one
        queue.sync {
            running = false
            expireTimer?.cancel()
            expireTimer = nil
            deliverer.abortGesture()
            resetGestureState()
        }
    }

    private func applyGestureSettings(to recognizer: inout GestureRecognizer) {
        recognizer.oneFingerDrag = settings.oneFingerDrag
        recognizer.threeFingerDrag = settings.threeFingerDrag
        recognizer.threeFingerAnchor = settings.threeFingerAnchor
        if let trackpad = settings.trackpad {
            recognizer.apply(trackpad)
            deliverer.momentumEnabled = trackpad.momentum
        } else {
            recognizer.enableAllTwoFingerGestures()
            deliverer.momentumEnabled = true
        }
    }

    /// Fresh tracker and recognizer (start, stop, display lost), keeping the current settings.
    private func resetGestureState() {
        tracker = ContactTracker()
        var fresh = GestureRecognizer()
        applyGestureSettings(to: &fresh)
        // In scroll mode a one-finger pan that starts on a toolbar or title bar still moves the window.
        fresh.dragZone = { [weak self] point in self?.startsWindowDrag(point) ?? false }
        recognizer = fresh
        contacts.removeAll()
        windowDragMemo = nil
        closeDockSwipe()
        dockPush = nil
        stopDockReturn()
        focusKeeper = nil
        if touchCount != 0 {
            touchCount = 0
            onTouchCount?(0, maxTouchCount)
        }
    }

    // MARK: input

    private func handle(report bytes: [UInt8], timestamp: UInt64) {
        guard let frame = ReportParser.parse(bytes) else { return }
        let now = Self.nanoseconds(timestamp)
        switch panelMode.observe(frame.source, atNs: now) {
        case .requestMultitouch:
            status("panel is sending single-touch (mouse) reports; asking it for multitouch")
            source.requestMultitouchMode()
        case .multitouchRestored:
            status("panel sends multitouch reports again")
        case nil:
            break
        }
        process(tracker.update(frame, atNs: now), now: now)
    }

    private func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.nanoseconds(mach_absolute_time())
            process(tracker.expire(atNs: now), now: now)
        }
        expireTimer = timer
        timer.resume()
    }

    private func process(_ events: [ContactEvent], now: UInt64) {
        guard !events.isEmpty else { return }
        for e in events {
            contacts[e.id] = e.phase == .ended ? nil : PanelPoint(x: e.x, y: e.y)
        }
        onContacts?(contacts)
        if focusKeeper != nil, events.contains(where: { $0.phase == .began }) {
            focusKeeper = nil   // a new touch decides focus itself
        }
        if !contacts.isEmpty, let push = dockPush, push.back, let home = dockReturn?.home {
            // A touch needs the cursor: stop pushing the Dock back, and try again once the fingers lift.
            dockPush = nil
            deliverer.end()
            watchForDockReturn(home: home)
        }
        if contacts.count != touchCount {
            touchCount = contacts.count
            maxTouchCount = max(maxTouchCount, touchCount)
            onTouchCount?(touchCount, maxTouchCount)
        }
        for action in recognizer.handle(events, atNs: now) {
            route(action)
        }
    }

    // MARK: routing

    private func route(_ action: GestureAction) {
        guard let mapper else { return }
        switch action {
        case let .tap(at, count):
            let p = point(mapper, at)
            begin(.tap, at: p)
            deliverer.click(at: p, count: count, button: .left)
            deliverer.end()
        case let .rightClick(at):
            let p = point(mapper, at)
            begin(.rightClick, at: p)
            deliverer.click(at: p, count: 1, button: .right)
            deliverer.end()
        case let .dragBegan(at, hold):
            let p = point(mapper, at)
            begin(.drag(hold: hold), at: p)
            deliverer.dragDown(at: p)
        case let .dragMoved(to):
            deliverer.dragMove(to: point(mapper, to))
        case let .dragEnded(at):
            deliverer.dragUp(at: point(mapper, at))
            deliverer.end()
        case let .scroll(dx, dy, phase):
            if phase == .began { begin(.scroll, at: centroid(mapper)) }
            let d = delta(mapper, dx, dy)
            deliverer.scroll(dx: d.x, dy: d.y, phase: phase)
        case let .scrollEnded(vx, vy):
            let v = delta(mapper, vx, vy)
            deliverer.scrollEnded(velocityX: v.x, velocityY: v.y)
        case let .magnify(value, phase):
            if phase == .began { begin(.magnify, at: centroid(mapper)) }
            deliverer.magnify(value, phase: phase)
        case let .rotate(degrees, phase):
            if phase == .began { begin(.rotate, at: centroid(mapper)) }
            deliverer.rotate(degrees, phase: phase)
        case let .dockSwipe(kind, delta, phase):
            if phase == .began { beginDockSwipe(kind, delta: delta, at: centroid(mapper)) }
            for step in swipeHold.pass(delta, phase) { postDockSwipe(kind, step) }
            if phase == .ended { endDockSwipe(kind) }
        case .dockSwipeCancelled:
            closeDockSwipe()
            status("dock swipe cancelled (palm)")
        case .notificationCenter:
            openNotificationCenter()
        }
    }

    /// Notification Center opens on the display that has the cursor, whichever clock opened it, so the
    /// hidden cursor waits on the touch display while the clock is pressed (`--system-ui-selftest`, nc-2).
    private func openNotificationCenter() {
        guard !settings.dryRun else { status("dry-run notification center"); return }
        guard let mapper, let clock = NotificationCenterOpener.clock() else { status("notification center → clock not found"); return }
        let p = contacts.isEmpty
            ? CGPoint(x: mapper.bounds.x + mapper.bounds.width / 2, y: mapper.bounds.y + mapper.bounds.height / 2)
            : centroid(mapper)
        deliverer.begin(.warp, at: p, appPID: nil, activate: false)
        let pressed = NotificationCenterOpener.press(clock)
        deliverer.end(returnDelay: Self.systemGestureCursorDelay)
        status("notification center → " + (pressed ? "clock pressed, cursor on the touch display" : "pressing the clock failed"))
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let mapper = self.mapper else { return }
            let panels = NotificationCenterOpener.openPanels().map { r in
                mapper.bounds.contains(ScreenPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)) ? "touch display" : "other display"
            }
            self.status("notification center result: " + (panels.isEmpty ? "not open" : "open on \(panels.joined(separator: ", "))"))
        }
    }

    // MARK: system gestures

    /// A Space switch acts on the display with the cursor, whichever display has the active menu bar
    /// (`--system-ui-selftest --spaces`, 2026-10-11): the hidden cursor waits on the touch display. Launchpad
    /// opens on the display with the Dock (see `bringDockIfNeeded`). Mission Control and App Exposé cover
    /// every display.
    private func beginDockSwipe(_ kind: DockSwipeKind, delta: Double, at p: CGPoint) {
        // A previous pinch still waiting for the Dock never reached the system: drop it and its push.
        dropHeldSwipe()
        if dockPush?.back == false { dockPush = nil }
        openDockSwipe = kind
        dockBroughtForPinch = false
        let activeBar = SystemDisplays.activeMenuBarDisplayUUID()
        status("\(kind) dock swipe → system (active menu bar on \(displayName(activeBar)))")
        guard !settings.dryRun else { return }
        switch kind {
        case .horizontal:
            spacesAtSwipeStart = SystemDisplays.currentSpaces()
            // macOS moves focus to the switched display afterwards; focus on another display is kept.
            focusBeforeSwitch = settings.keepFocusOnSpaceSwitch && activeBar != nil && activeBar != touchDisplayUUID
                ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
            deliverer.begin(.warp, at: p, appPID: nil, activate: false)
        case .pinch: bringDockIfNeeded(pinchInward: delta > 0, at: p)
        case .vertical: break
        }
    }

    // MARK: Launchpad and the Dock

    /// Launchpad opens on the display with the Dock. With "bring the Dock over", a pinch-in on the touch
    /// display first pushes the hidden cursor against the touch display's bottom edge until the Dock is there
    /// (the swipe is held meanwhile), as moving the Dock by hand does.
    private func bringDockIfNeeded(pinchInward: Bool, at p: CGPoint) {
        guard let mapper, DockLocator.isAtBottom, settings.launchpadDock != .leave,
              let dock = DockLocator.anchor() else { return }   // Dock position unknown: leave it alone
        let plan = LaunchpadDock.plan(mode: settings.launchpadDock, pinchInward: pinchInward, dockOnTouchDisplay: mapper.bounds.contains(dock))
        let home = dockHome(dock: dock, touch: mapper.bounds)
        guard plan.bringDock else {
            if plan.returnDock, let home { watchForDockReturn(home: home) }   // already here: still goes back after
            return
        }
        dockBroughtForPinch = true
        swipeHold.start()
        status("launchpad: bringing the Dock to the touch display first")
        pushDock(to: mapper.bounds, back: false) { [weak self] arrived, waitedMs in
            guard let self else { return }
            status(arrived ? "Dock on the touch display after \(Int(waitedMs)) ms"
                           : "Dock did not reach the touch display within \(Int(waitedMs)) ms")
            // Off the bottom edge, so the auto-hidden Dock slides away again behind Launchpad.
            deliverer.begin(.warp, at: p, appPID: nil, activate: false)
            for step in swipeHold.release() { postDockSwipe(.pinch, step) }
            if openDockSwipe == nil { deliverer.end(returnDelay: Self.systemGestureCursorDelay) }   // fingers already lifted
            if arrived, plan.returnDock, let home { watchForDockReturn(home: home) }
        }
    }

    private func dockHome(dock: ScreenPoint, touch: ScreenRect) -> ScreenRect? {
        LaunchpadDock.home(dock: dock, touch: touch, displays: SystemDisplays.online().map(SystemDisplays.rect),
                           main: SystemDisplays.rect(CGMainDisplayID()))
    }

    /// Choosing "then back" means the Dock lives off the touch display: one found there goes home once
    /// Launchpad is closed and no finger is on the panel (about 2 s later).
    private func sendDockHomeIfOnTouchDisplay() {
        guard !settings.dryRun, let mapper, DockLocator.isAtBottom, let dock = DockLocator.anchor(),
              mapper.bounds.contains(dock), let home = dockHome(dock: dock, touch: mapper.bounds) else { return }
        status("launchpad then back: the Dock is on the touch display; sending it home")
        watchForDockReturn(home: home)
    }

    /// Pushes the hidden cursor against `display`'s bottom edge until the Dock is there or the time is up,
    /// checking about every 45 ms, then calls `done(arrived, waited ms)`.
    private func pushDock(to display: ScreenRect, back: Bool, done: @escaping (Bool, Double) -> Void) {
        dockPushGeneration += 1
        dockPush = (dockPushGeneration, back)
        let edge = CGPoint(x: display.x + display.width / 2, y: display.y + display.height - 1)
        deliverer.begin(.warp, at: edge, appPID: nil, activate: false)
        pushDockStep(display: display, edge: edge, generation: dockPushGeneration, startedNs: DispatchTime.now().uptimeNanoseconds, step: 0, done: done)
    }

    private func pushDockStep(display: ScreenRect, edge: CGPoint, generation: Int, startedNs: UInt64, step: Int, done: @escaping (Bool, Double) -> Void) {
        guard dockPush?.generation == generation else { return }   // cancelled
        let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - startedNs) / 1e6
        let arrived = step % 3 == 2 && DockLocator.isDock(on: display) == true
        if arrived || waitedMs >= Self.dockPushTimeoutMs {
            dockPush = nil
            done(arrived, waitedMs)
            return
        }
        deliverer.nudge(at: edge, dx: 0, dy: 4)
        queue.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.pushDockStep(display: display, edge: edge, generation: generation, startedNs: startedNs, step: step + 1, done: done)
        }
    }

    /// "Bring the Dock over, then back": checks every 250 ms whether Launchpad has closed.
    private func watchForDockReturn(home: ScreenRect) {
        dockReturn = (DockReturnWatch(startedNs: DispatchTime.now().uptimeNanoseconds), home)
        guard dockReturnTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.pollDockReturn() }
        dockReturnTimer = timer
        timer.resume()
    }

    private func pollDockReturn() {
        guard var state = dockReturn, dockPush == nil else { return }
        let action = state.watch.poll(launchpadOpen: !DockLocator.launchpadWindows().isEmpty, fingersDown: !contacts.isEmpty,
                                      atNs: DispatchTime.now().uptimeNanoseconds)
        dockReturn = state
        switch action {
        case .wait:
            break
        case .stop:
            stopDockReturn()
            status("launchpad still open after 10 minutes: the Dock stays on the touch display")
        case .pushBack:
            stopDockReturn()
            status("launchpad closed: pushing the Dock back")
            dockReturn = (state.watch, state.home)   // kept, so a touch during the push can re-arm the watch
            pushDock(to: state.home, back: true) { [weak self] arrived, waitedMs in
                guard let self else { return }
                dockReturn = nil
                deliverer.end()
                status(arrived ? "Dock back after \(Int(waitedMs)) ms" : "Dock did not go back within \(Int(waitedMs)) ms")
            }
        }
    }

    private func stopDockReturn() {
        dockReturnTimer?.cancel()
        dockReturnTimer = nil
        dockReturn = nil
    }

    private func postDockSwipe(_ kind: DockSwipeKind, _ step: DockSwipeHold.Step) {
        let phase: DockSwipe.Phase = switch step.phase { case .began: .began; case .changed: .changed; case .ended: .ended }
        // Before macOS 26, pinch dock swipes need the inverted flag (verified on this Mac).
        dockSwipe.post(delta: step.delta, kind: synthKind(kind), phase: phase, inverted: kind == .pinch)
    }

    private func endDockSwipe(_ kind: DockSwipeKind) {
        openDockSwipe = nil
        guard kind != .vertical, !settings.dryRun else { return }
        // A pinch still bringing the Dock over gives the cursor back when the Dock has arrived.
        if kind == .horizontal || (dockBroughtForPinch && dockPush == nil) {
            deliverer.end(returnDelay: Self.systemGestureCursorDelay)
        }
        if kind == .horizontal, let pid = focusBeforeSwitch { keepFocus(on: pid) }
        focusBeforeSwitch = nil
        let before = spacesAtSwipeStart
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.logOutcome(of: kind, spacesBefore: before) }
    }

    /// Cancels an open dock swipe (palm, stop, display lost) and gives the cursor back.
    private func closeDockSwipe() {
        let heldBack = dropHeldSwipe()
        focusBeforeSwitch = nil
        guard let kind = openDockSwipe else { return }
        openDockSwipe = nil
        if !heldBack {
            dockSwipe.post(delta: 0, kind: synthKind(kind), phase: .cancelled, inverted: kind == .pinch)
        }
        if kind == .horizontal || dockBroughtForPinch {
            dockPush = nil
            deliverer.end()
        }
    }

    /// Discards a swipe held back for the Dock. True if one was held.
    @discardableResult
    private func dropHeldSwipe() -> Bool {
        swipeHold.cancel()
    }

    /// Gives focus back to `pid` the first time macOS moves it away within 1.5 s (`FocusKeeper`).
    private func keepFocus(on pid: pid_t) {
        focusKeeperGeneration += 1
        focusKeeper = (FocusKeeper(pid: pid, startedNs: DispatchTime.now().uptimeNanoseconds), focusKeeperGeneration)
        pollFocus(generation: focusKeeperGeneration)
    }

    private func pollFocus(generation: Int) {
        guard let state = focusKeeper, state.generation == generation else { return }   // cancelled
        switch state.keeper.poll(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                 atNs: DispatchTime.now().uptimeNanoseconds) {
        case .wait:
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pollFocus(generation: generation) }
        case let .restore(pid):
            focusKeeper = nil
            let app = NSRunningApplication(processIdentifier: pid)
            app?.activate()
            status("space switch: focus back to \(app?.localizedName ?? "pid \(pid)")")
        case .stop:
            focusKeeper = nil
        }
    }

    private func synthKind(_ kind: DockSwipeKind) -> DockSwipe.Kind {
        switch kind { case .horizontal: .horizontal; case .vertical: .vertical; case .pinch: .pinch }
    }

    /// Where the system put the result (diagnostic log line, read-only).
    private func logOutcome(of kind: DockSwipeKind, spacesBefore: [(String, UInt64)]) {
        switch kind {
        case .horizontal:
            let changed = SystemDisplays.currentSpaces()
                .filter { now in spacesBefore.first(where: { $0.0 == now.0 })?.1 != now.1 }
                .map { displayName($0.0) }
            status("space switch result: " + (changed.isEmpty ? "no Space changed" : "Space changed on \(changed.joined(separator: ", "))"))
        case .pinch:
            guard let mapper else { return }
            let overlays = WindowLocator.onScreenWindows().filter { $0.ownerName == "Dock" && $0.layer > 0 }.map { w in
                let centre = ScreenPoint(x: w.bounds.x + w.bounds.width / 2, y: w.bounds.y + w.bounds.height / 2)
                return "\(mapper.bounds.contains(centre) ? "touch display" : "other display") (layer \(w.layer), \(Int(w.bounds.width))×\(Int(w.bounds.height)))"
            }
            status("pinch result: Dock windows on " + (overlays.isEmpty ? "none" : overlays.joined(separator: ", ")))
        case .vertical:
            break
        }
    }

    private func displayName(_ uuid: String?) -> String {
        guard let uuid else { return "unknown display" }
        return uuid == touchDisplayUUID ? "touch display" : "other display"
    }

    /// Picks Direct or Warp once, at the start of the gesture.
    private func begin(_ kind: GestureKind, at p: CGPoint) {
        defer { windowDragMemo = nil }
        let windows = WindowLocator.onScreenWindows()
        let screenPoint = ScreenPoint(x: p.x, y: p.y)
        let window = WindowHitTester.topWindow(at: screenPoint, in: windows, excludingPID: ownPID)
        let override = window.flatMap { apps.bundleID(pid: $0.pid) }.flatMap { settings.appOverrides[$0] }
        let context = DeliveryContext(
            kind: kind, window: window, point: screenPoint,
            popupMenuVisible: WindowHitTester.popupMenuVisible(in: windows),
            appIsChromium: window.map { apps.isChromium(pid: $0.pid) } ?? false,
            appOverride: override,
            startsWindowDrag: kind == .drag(hold: false) && startsWindowDrag(at: p, windows: windows)
        )
        var mode = settings.policy.decide(context)
        if mode == .direct, !DirectTarget.isAvailable { mode = .warp }  // private call missing on this macOS
        let activate = DeliveryPolicy.needsActivation(kind)
        if mode == .direct, let window {
            let direct = DirectTarget(pid: window.pid, window: window.number, origin: CGPoint(x: window.bounds.x, y: window.bounds.y))
            deliverer.begin(.direct(direct), at: p, appPID: window.pid, activate: activate)
        } else {
            deliverer.begin(.warp, at: p, appPID: window?.pid, activate: activate)
        }
        status("\(kind) → \(mode) on \(window?.ownerName ?? "no window")")
    }

    /// Whether a pan/drag starting here moves the window (toolbar, title bar, title text). Runs on the queue.
    private func startsWindowDrag(_ p: PanelPoint) -> Bool {
        guard let mapper else { return false }
        let s = mapper.clampedPoint(x: p.x, y: p.y)
        return startsWindowDrag(at: CGPoint(x: s.x, y: s.y), windows: WindowLocator.onScreenWindows())
    }

    private func startsWindowDrag(at point: CGPoint, windows: [WindowInfo]) -> Bool {
        if let memo = windowDragMemo, abs(memo.point.x - point.x) < 0.5, abs(memo.point.y - point.y) < 0.5 { return memo.result }
        guard let window = WindowHitTester.topWindow(at: ScreenPoint(x: point.x, y: point.y), in: windows, excludingPID: ownPID),
              window.layer == 0 else { return false }
        // Accessibility queries make Chromium/Electron apps build their accessibility tree (slows them down);
        // they get the original 28 pt rule instead.
        let result = WindowDragArea.isDragArea(at: point, in: window, useAccessibility: !apps.isChromium(pid: window.pid))
        windowDragMemo = (point, result)
        if result { status("window drag area at \(Int(point.x)),\(Int(point.y)) on \(window.ownerName)") }
        return result
    }

    // MARK: geometry

    private func point(_ mapper: CoordinateMapper, _ p: PanelPoint) -> CGPoint {
        let s = mapper.clampedPoint(x: p.x, y: p.y)
        return CGPoint(x: s.x, y: s.y)
    }

    private func centroid(_ mapper: CoordinateMapper) -> CGPoint {
        guard !contacts.isEmpty else { return .zero }
        let n = Double(contacts.count)
        let c = PanelPoint(x: contacts.values.map(\.x).reduce(0, +) / n, y: contacts.values.map(\.y).reduce(0, +) / n)
        return point(mapper, c)
    }

    /// A panel-space delta in screen points (rotation-aware).
    private func delta(_ mapper: CoordinateMapper, _ dx: Double, _ dy: Double) -> CGPoint {
        let a = mapper.point(x: 0.5, y: 0.5)
        let b = mapper.point(x: 0.5 + dx, y: 0.5 + dy)
        return CGPoint(x: b.x - a.x, y: b.y - a.y)
    }

    private func refreshDisplay() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let found = ids.prefix(Int(count)).first {
            CGDisplayVendorNumber($0) == settings.displayVendor && CGDisplayModelNumber($0) == settings.displayModel
        }
        touchDisplayUUID = found.flatMap(SystemDisplays.uuid)
        guard let id = found else {
            if mapper != nil {
                // The monitor went away mid-use: close any open gesture now, it can't finish normally.
                deliverer.abortGesture()
                resetGestureState()
                status("touch display not found")
            }
            mapper = nil
            return
        }
        let b = CGDisplayBounds(id)
        let next = CoordinateMapper(bounds: ScreenRect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height), rotation: CGDisplayRotation(id))
        if next != mapper { status("touch display at \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))×\(Int(b.height)) rotation \(next.rotation)") }
        mapper = next
    }

    private func status(_ message: String) {
        onStatus?(message)
    }

    /// One function pointer for both registering and removing the display callback.
    private static let displayChanged: CGDisplayReconfigurationCallBack = { _, _, ctx in
        guard let ctx else { return }
        let pipeline = Unmanaged<InputPipeline>.fromOpaque(ctx).takeUnretainedValue()
        pipeline.queue.async { pipeline.refreshDisplay() }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
