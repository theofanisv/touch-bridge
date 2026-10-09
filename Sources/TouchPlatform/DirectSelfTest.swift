import AppKit
import CoreGraphics
import TouchCore

/// Diagnostic for Direct delivery: posts events straight to the Event Sink (another TouchBridge
/// instance) via DirectTarget, first while the sink is inactive (Finder frontmost), then while it
/// is active. Only ever targets our own Event Sink.
public enum DirectSelfTest {
    public static func run(log: @escaping (String) -> Void) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let sink = WindowLocator.onScreenWindows().first(where: { $0.ownerName == "TouchBridge" && $0.pid != me && $0.layer == 0 && $0.bounds.width >= 400 }) else {
            log("no Event Sink window found; open it first (menu → Open Event Sink)")
            return
        }
        log("sink pid \(sink.pid) window \(sink.number) bounds \(sink.bounds); CGEventSetWindowLocation available: \(DirectTarget.isAvailable)")
        let target = DirectTarget(pid: sink.pid, window: sink.number, origin: CGPoint(x: sink.bounds.x, y: sink.bounds.y))
        let source = CGEventSource(stateID: .privateState)

        func point(_ dx: Double, _ dy: Double) -> CGPoint { CGPoint(x: sink.bounds.x + dx, y: sink.bounds.y + dy) }
        func send(_ label: String, _ events: [CGEvent?]) {
            for event in events { event.map { target.post($0) } }
            log("posted \(label); frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            Thread.sleep(forTimeInterval: 0.5)
        }
        func round(_ tag: String, _ y: Double) {
            let p1 = point(150, y), p2 = point(300, y), p3 = point(450, y), p4 = point(600, y)
            send("\(tag) click", [
                EventSynth.mouse(.leftMouseDown, at: p1, button: .left, clickState: 1, eventNumber: 1, window: sink.number, source: source),
                EventSynth.mouse(.leftMouseUp, at: p1, button: .left, clickState: 1, eventNumber: 1, window: sink.number, source: source),
            ])
            send("\(tag) right-click", [
                EventSynth.mouse(.rightMouseDown, at: p2, button: .right, clickState: 1, eventNumber: 2, window: sink.number, source: source),
                EventSynth.mouse(.rightMouseUp, at: p2, button: .right, clickState: 1, eventNumber: 2, window: sink.number, source: source),
            ])
            send("\(tag) scroll", [
                EventSynth.scroll(dx: 0, dy: 12, at: p3, phase: .began, momentum: .none, window: sink.number, source: source),
                EventSynth.scroll(dx: 0, dy: 0, at: p3, phase: .ended, momentum: .none, window: sink.number, source: source),
            ])
            send("\(tag) pinch", [
                EventSynth.magnify(0.1, at: p4, phase: .began, window: sink.number, source: source),
                EventSynth.magnify(0, at: p4, phase: .ended, window: sink.number, source: source),
            ])
        }

        if CommandLine.arguments.contains("--button") {
            buttonVariants(sink: sink, target: target, source: source, log: log)
            return
        }
        if CommandLine.arguments.contains("--activation-timing") {
            activationTiming(sink: sink, target: target, source: source, log: log)
            return
        }

        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        Thread.sleep(forTimeInterval: 0.8)
        log("--- sink inactive (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) ---")
        round("inactive", 400)

        NSRunningApplication(processIdentifier: sink.pid)?.activate()
        Thread.sleep(forTimeInterval: 0.8)
        log("--- sink active (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) ---")
        round("active", 500)
        log("done")
    }

    /// From a background process: make Finder frontmost, activate the sink, wait N ms, click.
    private static func activationTiming(sink: WindowInfo, target: DirectTarget, source: CGEventSource?, log: (String) -> Void) {
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        let sinkApp = NSRunningApplication(processIdentifier: sink.pid)
        for (i, delay) in [0.0, 0.02, 0.05, 0.15].enumerated() {
            finder?.activate()
            Thread.sleep(forTimeInterval: 0.8)
            let accepted = sinkApp?.activate() ?? false
            Thread.sleep(forTimeInterval: delay)
            let p = CGPoint(x: sink.bounds.x + 120 + Double(i) * 150, y: sink.bounds.y + 450)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                EventSynth.mouse(type, at: p, button: .left, clickState: 1, eventNumber: Int64(10 + i), window: sink.number, source: source).map(target.post)
            }
            log("T\(i + 1): activate() returned \(accepted), waited \(Int(delay * 1000)) ms, clicked at x+\(120 + i * 150)")
            Thread.sleep(forTimeInterval: 0.5)
        }
        log("done")
    }

    /// Taps the sink's NSButton (window-local centre 76,60) with one change per variant; the sink logs
    /// "BUTTON action fired" when AppKit's control tracking accepts the press.
    private static func buttonVariants(sink: WindowInfo, target: DirectTarget, source: CGEventSource?, log: (String) -> Void) {
        NSRunningApplication(processIdentifier: sink.pid)?.activate()
        Thread.sleep(forTimeInterval: 0.6)
        let p = CGPoint(x: sink.bounds.x + 76, y: sink.bounds.y + 60)
        func tap(_ label: String, upDelay: TimeInterval = 0, extra: [UInt32: Int64] = [:], cursorOver: Bool = false) {
            let saved = CGEvent(source: nil)?.location ?? .zero
            if cursorOver { CGWarpMouseCursorPosition(p); Thread.sleep(forTimeInterval: 0.05) }
            for (i, type) in [CGEventType.leftMouseDown, .leftMouseUp].enumerated() {
                if i == 1, upDelay > 0 { Thread.sleep(forTimeInterval: upDelay) }
                guard let e = EventSynth.mouse(type, at: p, button: .left, clickState: 1, eventNumber: 40, window: sink.number, source: source) else { continue }
                for (field, value) in extra { e.setIntegerValueField(CGEventField(rawValue: field)!, value: value) }
                target.post(e)
            }
            if cursorOver { Thread.sleep(forTimeInterval: 0.1); CGWarpMouseCursorPosition(saved); CGAssociateMouseAndMouseCursorPosition(1) }
            log("posted \(label)")
            Thread.sleep(forTimeInterval: 0.7)
        }
        tap("B1 Direct, up immediately")
        tap("B2 Direct, up after 80 ms", upDelay: 0.08)
        tap("B3 Direct + field 106 (window height)", extra: [106: Int64(sink.bounds.height)])
        // The guard: only move the cursor if the sink really is topmost at the button.
        let top = WindowLocator.onScreenWindows().first { w in
            w.alpha > 0 && p.x >= w.bounds.x && p.x < w.bounds.x + w.bounds.width && p.y >= w.bounds.y && p.y < w.bounds.y + w.bounds.height
        }
        if top?.number == sink.number {
            tap("B4 Direct with the real cursor over the button", cursorOver: true)
        } else {
            log("B4 skipped: topmost window at the button is \(top?.ownerName ?? "none")")
        }
        log("done")
    }
}
