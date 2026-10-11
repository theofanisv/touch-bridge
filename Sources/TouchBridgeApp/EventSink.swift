import AppKit
import TouchCore
import TouchPlatform

/// Test window for the M1 compatibility matrix: shows and logs every event an ordinary app receives,
/// so we can see what Direct and Warp delivery actually produce. Opens on the touch display.
@MainActor
final class EventSink: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var sink: SinkView!
    private var tuioSource: DispatchSourceRead?
    private let log = FileLog(name: "eventsink")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let screen = NSScreen.screens.first { $0.localizedName.contains("ARZOPA") } ?? NSScreen.main!
        // Created *on* the touch screen: without `screen:` AppKit constrains the frame onto the main display.
        let frame = NSRect(x: screen.frame.width / 2 - 450, y: screen.frame.height / 2 - 300, width: 900, height: 600)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
        window.title = "TouchBridge Event Sink"
        window.isReleasedWhenClosed = false

        sink = SinkView(frame: NSRect(x: 0, y: 0, width: 900, height: 540), log: log, touchScreen: screen)
        sink.autoresizingMask = [.width, .height]
        let button = NSButton(title: "Button", target: sink, action: #selector(SinkView.buttonPressed))
        button.frame = NSRect(x: 16, y: 552, width: 120, height: 32)
        button.autoresizingMask = [.minYMargin]
        let field = NSTextField(frame: NSRect(x: 150, y: 556, width: 300, height: 24))
        field.placeholderString = "Text field (tap, then type)"
        field.autoresizingMask = [.minYMargin]
        let clear = NSButton(title: "Clear", target: sink, action: #selector(SinkView.clear))
        clear.frame = NSRect(x: 466, y: 552, width: 100, height: 32)
        clear.autoresizingMask = [.minYMargin]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        [sink, button, field, clear].forEach(content.addSubview)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        log.write("— event sink opened on \(screen.localizedName), window \(window.windowNumber), pid \(getpid()) —")
        logEveryEventEnteringTheApp()
        tapEveryEventSentToThisProcess()
        listenForTUIO()
    }

    /// Multitouch mode sends every finger as TUIO; listening like any TUIO app lets this window paint them all.
    private func listenForTUIO() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { log.write("TUIO: no socket"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(3333).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            log.write("TUIO: port 3333 is in use by another app; Multitouch fingers won't show here")
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0, let frame = TUIO.decode(Array(buffer.prefix(count))) else { return }
            MainActor.assumeIsolated { self?.sink.show(frame) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        tuioSource = source
        log.write("TUIO: listening on 127.0.0.1:3333 (Multitouch mode paints every finger here)")
    }

    /// A listen-only tap on every event the window server sends this process, including those that AppKit's
    /// swipe tracking pulls straight from the queue (the app-level monitor never sees them).
    private func tapEveryEventSentToThisProcess() {
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
            if type.rawValue != 5 {   // not mouse moved
                let fields = (100..<180).compactMap { i -> String? in
                    guard let field = CGEventField(rawValue: UInt32(i)) else { return nil }
                    let int = event.getIntegerValueField(field), double = event.getDoubleValueField(field)
                    if double != 0, double != Double(int) { return String(format: "%d=%.4g", i, double) }
                    return int == 0 ? nil : "\(i)=\(int)"
                }.joined(separator: " ")
                let tag = event.getIntegerValueField(.eventSourceUserData) == 0x5442_4752 ? " TOUCHBRIDGE" : ""
                sink.log.write("TAP type=\(type.rawValue)\(tag) \(fields)")
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreateForPid(pid: getpid(), place: .headInsertEventTap, options: .listenOnly,
                                                eventsOfInterest: CGEventMask.max, callback: callback,
                                                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.write("event tap for this process could not be created")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.write("tapping every event sent to this process")
    }

    /// Logs events as the app dequeues them, before any window or view sees them, so we can tell
    /// "never reached the app" from "reached the app but no window took it".
    private func logEveryEventEnteringTheApp() {
        let noise: Set<NSEvent.EventType> = [.mouseMoved, .appKitDefined, .systemDefined, .applicationDefined, .periodic, .cursorUpdate, .flagsChanged, .pressure]
        NSEvent.addLocalMonitorForEvents(matching: .any) { [log] event in
            guard !noise.contains(event.type) else { return event }
            let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x5442_4752 ? " TOUCHBRIDGE" : ""
            var fields = ""
            // Raw fields of mouse-downs, the first and last event of each scroll gesture, and gesture events,
            // to diff window-server-routed events against TouchBridge's.
            let scrollEdge = event.type == .scrollWheel && (event.phase == .began || event.phase == .ended || event.momentumPhase == .began)
            let gesture = [.gesture, .beginGesture, .endGesture, .swipe].contains(event.type)
            if event.type == .leftMouseDown || scrollEdge || gesture, let cg = event.cgEvent {
                fields = " fields:" + (0..<256).compactMap { i -> String? in
                    guard let field = CGEventField(rawValue: UInt32(i)) else { return nil }
                    let int = cg.getIntegerValueField(field)
                    let double = cg.getDoubleValueField(field)
                    if double != 0, double != Double(int) { return String(format: " %d=%.4g", i, double) }
                    return int == 0 ? nil : " \(i)=\(int)"
                }.joined()
            }
            if event.type == .scrollWheel || gesture {
                fields = String(format: " phase=%lu momentum=%lu dx=%.1f dy=%.1f precise=%@ inverted=%@",
                                event.phase.rawValue, event.momentumPhase.rawValue, event.scrollingDeltaX, event.scrollingDeltaY,
                                event.hasPreciseScrollingDeltas ? "y" : "n", event.isDirectionInvertedFromDevice ? "y" : "n") + fields
            }
            if event.type == .scrollWheel, event.phase == .began || event.phase == .ended || event.phase == .changed && event.scrollingDeltaX != 0,
               let cg = event.cgEvent {
                fields += " hid=" + (HIDEventBridge.describeAttached(cg)?.replacingOccurrences(of: "\n", with: " | ") ?? "none")
            }
            if event.type == .keyDown || event.type == .keyUp {
                fields += String(format: " key=%d chars=%@ mods=%lu", event.keyCode, event.characters ?? "", event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            }
            var windowLocation = ""
            if let cg = event.cgEvent, let getter = EventSink.getWindowLocation {
                let p = getter(cg)
                windowLocation = String(format: " wloc=%.0f,%.0f", p.x, p.y)
            }
            log.write(String(format: "APP type=%lu win=%ld loc=%.0f,%.0f%@%@%@", event.type.rawValue, event.windowNumber,
                             event.locationInWindow.x, event.locationInWindow.y, windowLocation, tag, fields))
            return event
        }
    }

    /// Private CoreGraphics getter for the window-relative location the window server stores in routed events.
    static let getWindowLocation: (@convention(c) (CGEvent) -> CGPoint)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent) -> CGPoint).self)
    }()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class SinkView: NSView {
    private let log: FileLog
    private var lines: [String] = []
    /// TUIO positions are fractions of the touch display, wherever this window is.
    private let touchScreen: NSScreen

    private struct Trail {
        let color: NSColor
        var points: [NSPoint]
    }

    /// Every stroke painted since the last Clear: one per finger (TUIO) and per mouse drag.
    private var trails: [Trail] = []
    private var liveTrail: [Int32: Int] = [:]
    private var liveFingers: [Int32: NSPoint] = [:]
    private var mouseTrail: Int?
    private var mostFingers = 0
    private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
                                             .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink]

    init(frame: NSRect, log: FileLog, touchScreen: NSScreen) {
        self.log = log
        self.touchScreen = touchScreen
        super.init(frame: frame)
    }

    private static func color(_ session: Int32) -> NSColor {
        palette[Int(UInt32(bitPattern: session) % UInt32(palette.count))]
    }

    /// One TUIO frame: extends each finger's trail, ends the trails of fingers that lifted.
    func show(_ frame: TUIO.Frame) {
        guard let window else { return }
        let alive = Set(frame.alive)
        for session in Array(liveFingers.keys) where !alive.contains(session) {
            liveFingers[session] = nil
            liveTrail[session] = nil
        }
        let s = touchScreen.frame
        for cursor in frame.cursors {
            let onScreen = NSPoint(x: s.minX + CGFloat(cursor.x) * s.width, y: s.maxY - CGFloat(cursor.y) * s.height)
            let p = convert(window.convertPoint(fromScreen: onScreen), from: nil)
            liveFingers[cursor.session] = p
            if let i = liveTrail[cursor.session] {
                trails[i].points.append(p)
            } else {
                liveTrail[cursor.session] = trails.count
                trails.append(Trail(color: Self.color(cursor.session), points: [p]))
            }
        }
        if liveFingers.count > mostFingers {
            mostFingers = liveFingers.count
            log.write("TUIO: \(mostFingers) fingers at once")
        }
        needsDisplay = true
    }

    @objc func clear() {
        trails.removeAll()
        liveTrail.removeAll()
        mouseTrail = nil
        mostFingers = liveFingers.count
        needsDisplay = true
    }

    private func paintMouse(_ e: NSEvent, starting: Bool, ending: Bool) {
        let p = convert(e.locationInWindow, from: nil)
        if starting || mouseTrail == nil {
            mouseTrail = trails.count
            trails.append(Trail(color: .systemGray, points: [p]))
        } else if let i = mouseTrail {
            trails[i].points.append(p)
        }
        if ending { mouseTrail = nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    @objc func buttonPressed() { record("BUTTON action fired") }

    override func mouseDown(with e: NSEvent) {
        paintMouse(e, starting: true, ending: false)
        record(describe("mouseDown", e) + " clicks=\(e.clickCount)")
    }
    override func mouseUp(with e: NSEvent) {
        paintMouse(e, starting: false, ending: true)
        record(describe("mouseUp", e) + " clicks=\(e.clickCount)")
    }
    override func mouseDragged(with e: NSEvent) {
        paintMouse(e, starting: false, ending: false)
        record(describe("mouseDragged", e))
    }
    override func rightMouseDown(with e: NSEvent) { record(describe("rightMouseDown", e)) }
    override func rightMouseUp(with e: NSEvent) { record(describe("rightMouseUp", e)) }
    override func scrollWheel(with e: NSEvent) {
        // What Safari/WebKit does for back/forward: start swipe tracking on a horizontal scroll that begins.
        if e.phase == .began, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
            record("SWIPE start? tracking-enabled=\(NSEvent.isSwipeTrackingFromScrollEventsEnabled) dx=\(e.scrollingDeltaX)")
            if NSEvent.isSwipeTrackingFromScrollEventsEnabled {
                var reported = 0
                e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: -1, max: 1) { [weak self] amount, phase, complete, _ in
                    reported += 1
                    if reported <= 3 || complete || phase == .ended || phase == .cancelled {
                        self?.record(String(format: "SWIPE tracking amount=%.2f phase=%lu complete=%@", amount, phase.rawValue, complete ? "y" : "n"))
                    }
                }
            }
        }
        record(describe("scroll", e) + String(format: " dx=%.1f dy=%.1f precise=%@ phase=%lu momentum=%lu",
                                              e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas ? "y" : "n",
                                              e.phase.rawValue, e.momentumPhase.rawValue))
    }
    override func magnify(with e: NSEvent) { record(describe("magnify", e) + String(format: " m=%.3f phase=%lu", e.magnification, e.phase.rawValue)) }
    override func rotate(with e: NSEvent) { record(describe("rotate", e) + String(format: " r=%.2f phase=%lu", e.rotation, e.phase.rawValue)) }
    override func swipe(with e: NSEvent) { record(describe("swipe", e) + String(format: " dx=%.0f dy=%.0f", e.deltaX, e.deltaY)) }

    private func describe(_ name: String, _ e: NSEvent) -> String {
        let p = convert(e.locationInWindow, from: nil)
        let state = "\(NSApp.isActive ? "active" : "inactive")/\(window?.isKeyWindow == true ? "key" : "not-key")"
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty ? "" : " mods=\(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
        return String(format: "%@ at %.0f,%.0f [%@]%@", name, p.x, p.y, state, mods)
    }

    private func record(_ line: String) {
        log.write(line)
        lines.append(line)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        for trail in trails {
            guard let first = trail.points.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if trail.points.count == 1 { path.line(to: first) }   // a tap: a dot
            for p in trail.points.dropFirst() { path.line(to: p) }
            trail.color.setStroke()
            path.stroke()
        }
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        for (session, p) in liveFingers {
            Self.color(session).withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)).fill()
            ("\(session)" as NSString).draw(at: NSPoint(x: p.x - 8, y: p.y - 9), withAttributes: label)
        }
        let status = "Fingers now: \(liveFingers.count) · most at once: \(mostFingers)    (Touch Mode → Multitouch paints every finger in colour; Drawing paints the mouse in grey)"
        (status as NSString).draw(at: NSPoint(x: 12, y: 8), withAttributes: label)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 12, y: 30 + CGFloat(i) * 17), withAttributes: attributes)
        }
    }
}
