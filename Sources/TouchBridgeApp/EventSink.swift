import AppKit

/// Test window for the M1 compatibility matrix: shows and logs every event an ordinary app receives,
/// so we can see what Direct and Warp delivery actually produce. Opens on the touch display.
@MainActor
final class EventSink: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let log = FileLog(name: "eventsink")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let screen = NSScreen.screens.first { $0.localizedName.contains("ARZOPA") } ?? NSScreen.main!
        // Created *on* the touch screen: without `screen:` AppKit constrains the frame onto the main display.
        let frame = NSRect(x: screen.frame.width / 2 - 450, y: screen.frame.height / 2 - 300, width: 900, height: 600)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
        window.title = "TouchBridge Event Sink"
        window.isReleasedWhenClosed = false

        let sink = SinkView(frame: NSRect(x: 0, y: 0, width: 900, height: 540), log: log)
        sink.autoresizingMask = [.width, .height]
        let button = NSButton(title: "Button", target: sink, action: #selector(SinkView.buttonPressed))
        button.frame = NSRect(x: 16, y: 552, width: 120, height: 32)
        button.autoresizingMask = [.minYMargin]
        let field = NSTextField(frame: NSRect(x: 150, y: 556, width: 300, height: 24))
        field.placeholderString = "Text field (tap, then type)"
        field.autoresizingMask = [.minYMargin]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        [sink, button, field].forEach(content.addSubview)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        log.write("— event sink opened on \(screen.localizedName), window \(window.windowNumber), pid \(getpid()) —")
        logEveryEventEnteringTheApp()
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

    init(frame: NSRect, log: FileLog) {
        self.log = log
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    @objc func buttonPressed() { record("BUTTON action fired") }

    override func mouseDown(with e: NSEvent) { record(describe("mouseDown", e) + " clicks=\(e.clickCount)") }
    override func mouseUp(with e: NSEvent) { record(describe("mouseUp", e) + " clicks=\(e.clickCount)") }
    override func mouseDragged(with e: NSEvent) { record(describe("mouseDragged", e)) }
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 12, y: 8 + CGFloat(i) * 17), withAttributes: attributes)
        }
    }
}
