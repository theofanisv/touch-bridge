import CoreGraphics
import Foundation

/// The trackpad's animated "dock swipes" (Mission Control, App Exposé, Spaces, Launchpad, Show Desktop),
/// synthesized as the private gesture events macOS 15 expects. The event format was learned from Mac Mouse Fix's
/// TouchSimulator (pre-macOS 27 path): per step, a type-30 event carrying a kIOHIDEventTypeDockSwipe subtype
/// with the phase, swipe type and accumulated progress, then a type-29 companion, both to the session tap.
/// The end event is re-sent after 0.2 s and 0.5 s because the system sometimes misses it under load.
final class DockSwipe {
    enum Kind: Int64 {
        /// Spaces / full-screen apps (four fingers left / right).
        case horizontal = 1
        /// Mission Control (up) / App Exposé (down).
        case vertical = 2
        /// Launchpad (pinch in) / Show Desktop (spread out).
        case pinch = 3
    }

    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    private var originOffset = 0.0
    private var lastDelta = 0.0
    private var resends: [DispatchWorkItem] = []
    private let queue: DispatchQueue
    var dryRun = false
    var log: (String) -> Void = { _ in }

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// `delta` is this step's progress; the system completes or cancels the swipe from the accumulated
    /// progress and the last step's direction when it ends.
    /// For experiments with type values beyond the known three.
    func postRaw(delta: Double, kind raw: Int64, phase: Phase) {
        rawKind = raw
        post(delta: delta, kind: .vertical, phase: phase)
        rawKind = nil
    }
    private var rawKind: Int64?

    func post(delta: Double, kind: Kind, phase requested: Phase, inverted: Bool = false) {
        var phase = requested
        switch phase {
        case .began:
            cancelResends()
            originOffset = delta
        case .changed:
            guard delta != 0 else { return }
            originOffset += delta
        case .ended, .cancelled:
            // Ending against the swipe's direction cancels it.
            if phase == .ended, (lastDelta < 0) != (originOffset < 0) { phase = .cancelled }
        }
        let exitSpeed = lastDelta * 100
        lastDelta = delta
        guard let (e30, e29) = makeEvents(kind: kind, phase: phase, exitSpeed: exitSpeed, inverted: inverted) else { return }
        if dryRun {
            log("dry-run dock swipe \(kind) \(phase) offset \(String(format: "%.3f", originOffset))")
            return
        }
        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)
        if phase == .ended || phase == .cancelled { scheduleResends(e30, e29) }
    }

    private func makeEvents(kind: Kind, phase: Phase, exitSpeed: Double, inverted: Bool) -> (CGEvent, CGEvent)? {
        guard let e30 = CGEvent(source: nil), let e29 = CGEvent(source: nil) else { return nil }
        func f(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
        let type = rawKind ?? kind.rawValue
        let typeBits = Double(Float(bitPattern: UInt32(type)))   // raw bits, like the trackpad's events

        e29.setDoubleValueField(f(55), value: 29)          // NSEventTypeGesture
        e29.setDoubleValueField(f(41), value: 33231)

        e30.setDoubleValueField(f(55), value: 30)
        e30.setDoubleValueField(f(110), value: 23)          // kIOHIDEventTypeDockSwipe
        e30.setDoubleValueField(f(132), value: Double(phase.rawValue))
        e30.setDoubleValueField(f(134), value: Double(phase.rawValue))
        e30.setDoubleValueField(f(124), value: originOffset)
        e30.setIntegerValueField(f(135), value: Int64(Float(originOffset).bitPattern))
        e30.setDoubleValueField(f(41), value: 33231)
        e30.setDoubleValueField(f(119), value: typeBits)
        e30.setDoubleValueField(f(139), value: typeBits)
        e30.setDoubleValueField(f(123), value: Double(type))
        e30.setDoubleValueField(f(165), value: Double(type))
        e30.setIntegerValueField(f(136), value: inverted ? 1 : 0)
        if phase == .ended || phase == .cancelled {
            e30.setDoubleValueField(f(129), value: exitSpeed)
            e30.setDoubleValueField(f(130), value: exitSpeed)
        }
        return (e30, e29)
    }

    private func scheduleResends(_ e30: CGEvent, _ e29: CGEvent) {
        cancelResends()
        for delay in [0.2, 0.5] {
            let work = DispatchWorkItem {
                e30.post(tap: .cgSessionEventTap)
                e29.post(tap: .cgSessionEventTap)
            }
            resends.append(work)
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelResends() {
        resends.forEach { $0.cancel() }
        resends.removeAll()
    }
}
