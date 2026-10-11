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

        if CommandLine.arguments.contains("--swipe") {
            swipeVariants(sink: sink, target: target, source: source, log: log)
            return
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

    /// Horizontal two-finger swipes posted to the sink with progressively more of the fields a real trackpad
    /// swipe carries, to find what macOS's swipe tracking (Safari back/forward) needs. The sink logs
    /// "SWIPE tracking … complete=y amount=1.00" when a swipe completes.
    private static func swipeVariants(sink: WindowInfo, target: DirectTarget, source: CGEventSource?, log: (String) -> Void) {
        NSRunningApplication(processIdentifier: sink.pid)?.activate()
        Thread.sleep(forTimeInterval: 0.6)
        let p = CGPoint(x: sink.bounds.x + 450, y: sink.bounds.y + 300)
        func f(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
        typealias Extra = (CGEvent, Double) -> Void   // (event, dx of this event)
        let variants: [(String, Extra)] = [
            ("S1 baseline", { _, _ in }),
            ("S2 + accelerated/raw horizontal deltas (175, 177)", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
            }),
            ("S3 + field 137 = 1", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
                e.setIntegerValueField(f(137), value: 1)
            }),
            ("S4 + sender id 87 (the trackpad's)", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
                e.setIntegerValueField(f(137), value: 1)
                e.setIntegerValueField(f(87), value: 4_294_970_419)
            }),
            // Field 126 holds the underlying HID event type as raw bits: 6 = kIOHIDEventTypeScroll on the trackpad.
            ("S5 + 126 = HID type scroll (6)", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
                e.setIntegerValueField(f(137), value: 1)
                e.setIntegerValueField(f(87), value: 4_294_970_419)
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
            }),
            ("S6 + 169 = HID timestamp", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
                e.setIntegerValueField(f(137), value: 1)
                e.setIntegerValueField(f(87), value: 4_294_970_419)
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(169), value: Int64(mach_absolute_time()))
            }),
            ("S7 + 101 = 60", { e, dx in
                e.setDoubleValueField(f(175), value: -dx * 0.0222)
                e.setIntegerValueField(f(177), value: Int64(-dx.rounded()))
                e.setIntegerValueField(f(137), value: 1)
                e.setIntegerValueField(f(87), value: 4_294_970_419)
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(169), value: Int64(mach_absolute_time()))
                e.setIntegerValueField(f(101), value: 60)
            }),
            // Fields 119/139 carry the gesture phase as raw bits (1 began, 2 changed, 4 ended) on trackpad events;
            // CGEventCreateScrollWheelEvent2 leaves them at 1 for every event.
            ("S8 baseline + gesture phase in 119/139", { _, _ in }),
            ("S9 S8 + direction flag 137", { e, _ in e.setIntegerValueField(f(137), value: 1) }),
            // Realistic deltas from the trackpad's changed events: 175 (accelerated) ≈ -dx/10, 177 (raw) ≈ -1.4·dx,
            // written as doubles (an integer write to 177 was silently dropped).
            ("S10 S9 + realistic 175/177 as doubles", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
            }),
            ("S11 S10 + HID type 6 + sender id", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
            }),
            // An attached HID scroll event, as real trackpad events carry (filled in per event below).
            ("S12 S11 + attached HID scroll event", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
            }),
            // The trackpad's full structure: built-in parent + child scroll (finger travel) …
            ("S13 S11 + trackpad-shaped HID scroll with child", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
            }),
            // As the hardware sends them: HID-system source state, no poster fields (S15), and also routed by the
            // window server to the window under the (hidden) cursor instead of posted to the app (S16).
            ("S15 S14 + HID-system source, no poster fields", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
                e.setIntegerValueField(f(101), value: 60)
                e.setIntegerValueField(f(169), value: Int64(mach_absolute_time()))
                for n: UInt32 in [41, 42, 43, 44] { e.setIntegerValueField(f(n), value: 0) }
                e.setIntegerValueField(f(45), value: 1)
            }),
            ("S16 S15 routed through the window server", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
                e.setIntegerValueField(f(101), value: 60)
                e.setIntegerValueField(f(169), value: Int64(mach_absolute_time()))
                for n: UInt32 in [41, 42, 43, 44] { e.setIntegerValueField(f(n), value: 0) }
                e.setIntegerValueField(f(45), value: 1)
            }),
            // The gesture stream (type 29: subtype 61, 6 per move, 62) that real swipes carry next to the scrolls.
            ("S17 S8 + the trackpad's scroll-gesture stream", { _, _ in }),
            // … plus the multitouch driver's vendor event.
            ("S14 S13 + multitouch vendor event", { e, dx in
                e.setIntegerValueField(f(137), value: 1)
                e.setDoubleValueField(f(175), value: -dx / 10)
                e.setDoubleValueField(f(177), value: -(dx * 1.4).rounded())
                e.setDoubleValueField(f(126), value: Double(Float(bitPattern: 6)))
                e.setIntegerValueField(f(87), value: 4_294_970_419)
            }),
        ]
        let only = CommandLine.arguments.firstIndex(of: "--from").map { Int(CommandLine.arguments[$0 + 1]) ?? 1 } ?? 1
        for (label, extra) in variants.dropFirst(only - 1) {
            let gesturePhase = ["S8", "S9", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17"].contains { label.hasPrefix($0 + " ") }
            let gestureStream = label.hasPrefix("S17 ")
            let attachHID = label.hasPrefix("S12 ")
            let trackpadHID = ["S13", "S14", "S15", "S16"].contains { label.hasPrefix($0 + " ") }
            let vendor = ["S14", "S15", "S16"].contains { label.hasPrefix($0 + " ") }
            let routed = label.hasPrefix("S16 ")
            let saved = CGEvent(source: nil)?.location
            if routed {
                CursorVisibility.allowHidingInBackground()
                CursorVisibility.hide()
                CGWarpMouseCursorPosition(p)
            }
            defer {
                if routed, let saved {
                    CGWarpMouseCursorPosition(saved)
                    CGAssociateMouseAndMouseCursorPosition(1)
                    CursorVisibility.show()
                }
            }
            var changedCount = 0
            if attachHID || trackpadHID { log("HID bridge available: \(HIDEventBridge.isAvailable)") }
            func post(_ dx: Double, _ phase: EventSynth.Phase?, _ momentum: EventSynth.MomentumPhase) {
                guard let e = EventSynth.scroll(dx: dx, dy: 0, at: p, phase: phase, momentum: momentum, window: sink.number, source: source) else { return }
                extra(e, dx)
                if gesturePhase {
                    let bits: UInt32 = switch phase { case .began: 1; case .changed: 2; case .ended: 4; case nil: 0 }
                    e.setDoubleValueField(f(119), value: Double(Float(bitPattern: bits)))
                    e.setDoubleValueField(f(139), value: Double(Float(bitPattern: bits)))
                }
                if attachHID, let phase {
                    let hidPhase: HIDEventBridge.Phase = switch phase { case .began: .began; case .changed: .changed; case .ended: .ended }
                    HIDEventBridge.attachScroll(to: e, x: -(dx * 1.4).rounded(), y: 0, phase: hidPhase, senderID: 4_294_970_419)
                }
                if trackpadHID, let phase {
                    let hidPhase: HIDEventBridge.Phase = switch phase { case .began: .began; case .changed: .changed; case .ended: .ended }
                    if phase == .changed { changedCount += 1 }
                    HIDEventBridge.attachTrackpadScroll(to: e, dx: dx, dy: 0, phase: hidPhase, senderID: 4_294_970_419,
                                                        vendorData: vendor, gestureUnderway: changedCount > 8)
                }
                if routed { e.post(tap: .cghidEventTap) } else { target.post(e) }
                if gestureStream, let phase {
                    var parts: [EventSynth.ScrollGesture] = []
                    switch phase {
                    case .began: parts = [.begin]
                    case .changed: parts = [.move(dx: dx, dy: 0, phase: .changed)]
                    case .ended: parts = [.move(dx: 0, dy: 0, phase: .ended), .end]
                    }
                    for part in parts { EventSynth.scrollGesture(part, at: p, window: sink.number, source: source).map { target.post($0) } }
                }
            }
            log("posting \(label)")
            post(2, .began, .none)
            for _ in 0..<14 { Thread.sleep(forTimeInterval: 0.016); post(18, .changed, .none) }
            Thread.sleep(forTimeInterval: 0.016); post(0, .ended, .none)
            for i in 0..<10 { Thread.sleep(forTimeInterval: 0.016); post(40 - Double(i) * 4, nil, i == 0 ? .begin : .continue) }
            post(0, nil, .end)
            Thread.sleep(forTimeInterval: 1.2)
        }
        log("done")
    }
}
