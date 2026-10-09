import Testing
@testable import TouchCore

private func frame(_ contacts: [(UInt8, Bool, Double, Double)]) -> TouchFrame {
    TouchFrame(source: .digitizer, contacts: contacts.map { Contact(id: $0.0, touching: $0.1, x: $0.2, y: $0.3) }, scanTime: 0)
}

private let ms: UInt64 = 1_000_000

@Test func firstTouchBegins() {
    var tracker = ContactTracker()
    let events = tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 0)
    #expect(events == [ContactEvent(id: 1, phase: .began, x: 0.2, y: 0.3)])
    #expect(tracker.activeCount == 1)
}

@Test func movementOfAnActiveContactIsReported() {
    var tracker = ContactTracker()
    _ = tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 0)
    #expect(tracker.update(frame([(1, true, 0.25, 0.3)]), atNs: 8 * ms) == [ContactEvent(id: 1, phase: .moved, x: 0.25, y: 0.3)])
}

@Test func unchangedPositionReportsNothing() {
    var tracker = ContactTracker()
    _ = tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 0)
    #expect(tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 8 * ms).isEmpty)
}

@Test func tipOffEndsTheContact() {
    var tracker = ContactTracker()
    _ = tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 0)
    #expect(tracker.update(frame([(1, false, 0.21, 0.3)]), atNs: 8 * ms) == [ContactEvent(id: 1, phase: .ended, x: 0.21, y: 0.3)])
    #expect(tracker.activeCount == 0)
}

@Test func contactMissingFromFrameEndsAtItsLastPosition() {
    var tracker = ContactTracker()
    _ = tracker.update(frame([(1, true, 0.2, 0.3), (2, true, 0.6, 0.6)]), atNs: 0)
    let events = tracker.update(frame([(2, true, 0.6, 0.6)]), atNs: 8 * ms)
    #expect(events == [ContactEvent(id: 1, phase: .ended, x: 0.2, y: 0.3)])
    #expect(tracker.activeCount == 1)
}

@Test func liftedContactThatWasNeverActiveIsIgnored() {
    var tracker = ContactTracker()
    #expect(tracker.update(frame([(4, false, 0.5, 0.5)]), atNs: 0).isEmpty)
}

@Test func silenceLongerThanTheLiftTimeoutEndsEverything() {
    var tracker = ContactTracker(liftTimeoutNs: 100 * ms)
    _ = tracker.update(frame([(1, true, 0.2, 0.3)]), atNs: 0)
    #expect(tracker.expire(atNs: 50 * ms).isEmpty)
    #expect(tracker.expire(atNs: 150 * ms) == [ContactEvent(id: 1, phase: .ended, x: 0.2, y: 0.3)])
    #expect(tracker.activeCount == 0)
}

@Test func eventsAreOrderedEndedThenBeganThenMoved() {
    var tracker = ContactTracker()
    _ = tracker.update(frame([(1, true, 0.1, 0.1), (2, true, 0.5, 0.5)]), atNs: 0)
    let events = tracker.update(frame([(2, true, 0.55, 0.5), (3, true, 0.9, 0.9)]), atNs: 8 * ms)
    #expect(events.map(\.phase) == [.ended, .began, .moved])
    #expect(events.map(\.id) == [1, 3, 2])
}

// Owner requirement (2026-10-09): able to watch up to 10 fingers (future painting apps / games).
@Test func tracksTenSimultaneousFingersThroughTheirWholeLifecycle() {
    var tracker = ContactTracker()
    let down = (0..<10).map { (UInt8($0), true, 0.05 + Double($0) * 0.09, 0.5) }
    let began = tracker.update(frame(down), atNs: 0)
    #expect(began.filter { $0.phase == .began }.count == 10)
    #expect(tracker.activeCount == 10)

    let moved = tracker.update(frame(down.map { ($0.0, true, $0.2, 0.6) }), atNs: 8 * ms)
    #expect(moved.filter { $0.phase == .moved }.count == 10)

    let lifted = tracker.update(frame(down.map { ($0.0, false, $0.2, 0.6) }), atNs: 16 * ms)
    #expect(lifted.filter { $0.phase == .ended }.count == 10)
    #expect(tracker.activeCount == 0)
}
