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
    /// The window-drag answer for the gesture being classified, so Accessibility is asked once.
    private var windowDragMemo: (point: CGPoint, result: Bool)?

    public init() {}

    public func update(_ change: @escaping @Sendable (inout PipelineSettings) -> Void) {
        queue.async { [self] in
            change(&settings)
            deliverer.dryRun = settings.dryRun
            deliverer.focusMode = settings.focus
            recognizer.oneFingerDrag = settings.oneFingerDrag
            refreshDisplay()
        }
    }

    public func start() {
        source.onStatus = { [weak self] in self?.status($0) }
        source.onReport = { [weak self] timestamp, bytes in self?.handle(report: bytes, timestamp: timestamp) }
        queue.async { [self] in
            resetGestureState()
            deliverer.log = { [weak self] in self?.status($0) }
            deliverer.dryRun = settings.dryRun
            deliverer.releaseStuckPress()
            mapper = nil  // so the display line is reported even if settings changed before start
            refreshDisplay()
            startExpiryTimer()
        }
        CGDisplayRegisterReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        source.start()
    }

    public func stop() {
        CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        source.stop()   // first, so no frame can open a new gesture while we close the current one
        queue.sync {
            expireTimer?.cancel()
            expireTimer = nil
            deliverer.abortGesture()
            resetGestureState()
        }
    }

    /// Fresh tracker and recognizer (start, stop, display lost), keeping the current settings.
    private func resetGestureState() {
        tracker = ContactTracker()
        var fresh = GestureRecognizer()
        fresh.oneFingerDrag = settings.oneFingerDrag
        // In scroll mode a one-finger pan that starts on a toolbar or title bar still moves the window.
        fresh.dragZone = { [weak self] point in self?.startsWindowDrag(point) ?? false }
        recognizer = fresh
        contacts.removeAll()
        windowDragMemo = nil
        if touchCount != 0 {
            touchCount = 0
            onTouchCount?(0, maxTouchCount)
        }
    }

    // MARK: input

    private func handle(report bytes: [UInt8], timestamp: UInt64) {
        guard let frame = ReportParser.parse(bytes) else { return }
        let now = Self.nanoseconds(timestamp)
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
        }
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
