import Foundation
import Testing
@testable import TouchCore

private let ms: UInt64 = 1_000_000
private let config = GestureConfig()
/// Normalized horizontal/vertical distance for a length in millimetres on this panel.
private func mmX(_ mm: Double) -> Double { mm / config.panelWidthMm }
private func mmY(_ mm: Double) -> Double { mm / config.panelHeightMm }

private func began(_ id: UInt8, _ x: Double, _ y: Double) -> ContactEvent { ContactEvent(id: id, phase: .began, x: x, y: y) }
private func moved(_ id: UInt8, _ x: Double, _ y: Double) -> ContactEvent { ContactEvent(id: id, phase: .moved, x: x, y: y) }
private func ended(_ id: UInt8, _ x: Double, _ y: Double) -> ContactEvent { ContactEvent(id: id, phase: .ended, x: x, y: y) }

private struct Script {
    var recognizer: GestureRecognizer
    var actions: [GestureAction] = []
    init(oneFingerDrag: OneFingerDragMode = .clickAndDrag, configure: (inout GestureConfig) -> Void = { _ in }) {
        var c = config
        c.oneFingerDrag = oneFingerDrag
        configure(&c)
        recognizer = GestureRecognizer(config: c)
    }
    mutating func at(_ t: UInt64, _ events: ContactEvent...) {
        actions += recognizer.handle(events, atNs: t * ms)
    }
}

// MARK: single finger

@Test func quickStationaryTouchIsATapOnLift() {
    var s = Script()
    s.at(0, began(0, 0.5, 0.5))
    #expect(s.actions.isEmpty, "nothing is posted before the gesture is classified")
    s.at(80, ended(0, 0.5, 0.5))
    #expect(s.actions == [.tap(at: PanelPoint(x: 0.5, y: 0.5), count: 1)])
}

@Test func jitterBelowTheSlopIsStillATapAtTheTouchDownPoint() {
    var s = Script()
    s.at(0, began(0, 0.5, 0.5))
    s.at(30, moved(0, 0.5 + mmX(2), 0.5))
    s.at(60, ended(0, 0.5 + mmX(2), 0.5))
    #expect(s.actions == [.tap(at: PanelPoint(x: 0.5, y: 0.5), count: 1)])
}

@Test func secondAndThirdTapNearbyCountUpAndSnapToTheFirstTap() {
    var s = Script()
    s.at(0, began(0, 0.5, 0.5)); s.at(60, ended(0, 0.5, 0.5))
    s.at(200, began(1, 0.5 + mmX(5), 0.5)); s.at(260, ended(1, 0.5 + mmX(5), 0.5))
    s.at(400, began(2, 0.5, 0.5 + mmY(5))); s.at(460, ended(2, 0.5, 0.5 + mmY(5)))
    let first = PanelPoint(x: 0.5, y: 0.5)
    #expect(s.actions == [.tap(at: first, count: 1), .tap(at: first, count: 2), .tap(at: first, count: 3)])
}

@Test func aFarAwayOrLateSecondTapStartsANewSequence() {
    var s = Script()
    s.at(0, began(0, 0.2, 0.2)); s.at(60, ended(0, 0.2, 0.2))
    s.at(200, began(1, 0.2 + mmX(20), 0.2)); s.at(260, ended(1, 0.2 + mmX(20), 0.2))
    s.at(2000, began(2, 0.2 + mmX(20), 0.2)); s.at(2060, ended(2, 0.2 + mmX(20), 0.2))
    #expect(s.actions.map { if case let .tap(_, count) = $0 { count } else { -1 } } == [1, 1, 1])
}

@Test func stationaryHoldIsARightClickOnLift() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4))
    s.at(700, moved(0, 0.4 + mmX(1), 0.4))
    #expect(s.actions.isEmpty)
    s.at(900, ended(0, 0.4 + mmX(1), 0.4))
    #expect(s.actions == [.rightClick(at: PanelPoint(x: 0.4, y: 0.4))])
}

@Test func movingBeyondTheSlopEarlyStartsADragFromTheTouchDownPoint() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.3))
    s.at(50, moved(0, 0.3 + mmX(5), 0.3))
    s.at(70, moved(0, 0.3 + mmX(10), 0.3))
    s.at(90, ended(0, 0.3 + mmX(10), 0.3))
    #expect(s.actions == [
        .dragBegan(at: PanelPoint(x: 0.3, y: 0.3), hold: false),
        .dragMoved(to: PanelPoint(x: 0.3 + mmX(5), y: 0.3)),
        .dragMoved(to: PanelPoint(x: 0.3 + mmX(10), y: 0.3)),
        .dragEnded(at: PanelPoint(x: 0.3 + mmX(10), y: 0.3)),
    ])
}

@Test func holdThenMoveIsAHoldDrag() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.3))
    s.at(600, moved(0, 0.3 + mmX(5), 0.3))
    #expect(s.actions.first == .dragBegan(at: PanelPoint(x: 0.3, y: 0.3), hold: true))
}

// MARK: two fingers

@Test func twoFingersMovingTogetherScrollAndEndWithVelocity() throws {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4))
    s.at(40, began(1, 0.5, 0.4))
    s.at(60, moved(0, 0.4, 0.4 + mmY(3)), moved(1, 0.5, 0.4 + mmY(3)))
    #expect(s.actions.isEmpty, "3 mm is below the scroll lock")
    s.at(70, moved(0, 0.4, 0.4 + mmY(6)), moved(1, 0.5, 0.4 + mmY(6)))
    s.at(80, moved(0, 0.4, 0.4 + mmY(9)), moved(1, 0.5, 0.4 + mmY(9)))
    s.at(90, ended(0, 0.4, 0.4 + mmY(9)))

    guard case let .scroll(dx0, dy0, .began) = s.actions.first else { Issue.record("expected scroll began, got \(s.actions)"); return }
    #expect(abs(dx0) < 1e-9)
    #expect(abs(dy0 - mmY(6)) < 1e-9, "the began event carries the movement since touch-down")
    guard case let .scroll(_, dy1, .changed) = s.actions[1] else { Issue.record("expected scroll changed"); return }
    #expect(abs(dy1 - mmY(3)) < 1e-9)
    guard case let .scrollEnded(vx, vy) = try #require(s.actions.last) else { Issue.record("expected scrollEnded"); return }
    #expect(abs(vx) < 1e-9)
    #expect(vy > 0)
}

@Test func spreadingTwoFingersApartMagnifies() throws {
    var s = Script()
    s.at(0, began(0, 0.45, 0.5), began(1, 0.55, 0.5))
    s.at(30, moved(0, 0.43, 0.5), moved(1, 0.57, 0.5))   // distance ×1.4
    s.at(45, moved(0, 0.42, 0.5), moved(1, 0.58, 0.5))
    s.at(60, ended(1, 0.58, 0.5))
    guard case let .magnify(d0, .began) = s.actions.first else { Issue.record("expected magnify began, got \(s.actions)"); return }
    #expect(abs(d0 - 0.4) < 1e-9)
    guard case let .magnify(d1, .changed) = s.actions[1] else { Issue.record("expected magnify changed"); return }
    #expect(d1 > 0)
    #expect(s.actions.last == .magnify(delta: 0, phase: .ended))
}

@Test func twistingCounterclockwiseRotatesPositive() throws {
    var s = Script()
    // Two fingers 40 mm apart horizontally; the right finger moves up, the left finger down: counterclockwise on screen.
    let cx = 0.5, cy = 0.5
    s.at(0, began(0, cx - mmX(20), cy), began(1, cx + mmX(20), cy))
    s.at(30, moved(0, cx - mmX(20), cy + mmY(5)), moved(1, cx + mmX(20), cy - mmY(5)))
    s.at(60, ended(0, cx - mmX(20), cy + mmY(5)))
    guard case let .rotate(degrees, .began) = s.actions.first else { Issue.record("expected rotate began, got \(s.actions)"); return }
    #expect(abs(degrees - atan2(5, 20) * 180 / .pi) < 1e-6)
    #expect(s.actions.last == .rotate(degrees: 0, phase: .ended))
}

@Test func twoFingersLiftedWithoutMovingDoNothing() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4), began(1, 0.5, 0.4))
    s.at(80, ended(0, 0.4, 0.4), ended(1, 0.5, 0.4))
    #expect(s.actions.isEmpty)
}

@Test func aSecondFingerArrivingLateIsIgnored() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.3))
    s.at(300, began(1, 0.6, 0.6))
    s.at(320, moved(0, 0.3 + mmX(6), 0.3))
    #expect(s.actions.first == .dragBegan(at: PanelPoint(x: 0.3, y: 0.3), hold: false))
}

@Test func theFingerLeftAfterATwoFingerGestureDoesNothingUntilAllLift() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4), began(1, 0.5, 0.4))
    s.at(30, moved(0, 0.4, 0.4 + mmY(10)), moved(1, 0.5, 0.4 + mmY(10)))
    s.at(40, ended(1, 0.5, 0.4 + mmY(10)))
    let count = s.actions.count
    s.at(60, moved(0, 0.4 + mmX(20), 0.4 + mmY(10)))
    s.at(80, ended(0, 0.4 + mmX(20), 0.4 + mmY(10)))
    #expect(s.actions.count == count)
    s.at(500, began(2, 0.7, 0.7)); s.at(560, ended(2, 0.7, 0.7))
    #expect(s.actions.last == .tap(at: PanelPoint(x: 0.7, y: 0.7), count: 1))
}

// MARK: palm

@Test func morethanThreeFingersCancelsAnActiveDragAndIgnoresTheRest() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.3))
    s.at(50, moved(0, 0.3 + mmX(6), 0.3))
    s.at(60, began(1, 0.5, 0.5), began(2, 0.6, 0.6), began(3, 0.7, 0.7))
    #expect(s.actions.last == .dragEnded(at: PanelPoint(x: 0.3 + mmX(6), y: 0.3)))
    let count = s.actions.count
    s.at(80, moved(0, 0.3 + mmX(20), 0.3))
    s.at(90, ended(0, 0.3, 0.3), ended(1, 0.5, 0.5), ended(2, 0.6, 0.6), ended(3, 0.7, 0.7))
    #expect(s.actions.count == count)
}


// MARK: two-finger classification by how the fingers move

@Test func aSloppyScrollWhoseFingerGapChangesStillScrolls() {
    var s = Script()
    s.at(0, began(0, 0.45, 0.4), began(1, 0.55, 0.4))   // 31 mm apart
    // Fingers drift apart by 10 % while starting to move down together…
    s.at(20, moved(0, 0.45 - mmX(1.6), 0.4 + mmY(2)), moved(1, 0.55 + mmX(1.6), 0.4 + mmY(2)))
    // …then keep moving down.
    s.at(40, moved(0, 0.45 - mmX(2), 0.4 + mmY(6)), moved(1, 0.55 + mmX(2), 0.4 + mmY(6)))
    guard case .scroll(_, _, .began) = s.actions.first else { Issue.record("expected scroll, got \(s.actions)"); return }
}

@Test func pinchingWithOneFingerHeldStillMagnifies() {
    var s = Script()
    s.at(0, began(0, 0.40, 0.5), began(1, 0.55, 0.5))
    s.at(20, moved(1, 0.55 - mmX(3), 0.5))
    s.at(40, moved(1, 0.55 - mmX(6), 0.5))
    guard case let .magnify(delta, .began) = s.actions.first else { Issue.record("expected magnify, got \(s.actions)"); return }
    #expect(delta < 0)
}

@Test func circlingWithOneFingerHeldStillRotates() {
    var s = Script()
    s.at(0, began(0, 0.45, 0.5), began(1, 0.55, 0.5))   // 31 mm apart horizontally
    s.at(30, moved(1, 0.55, 0.5 - mmY(6)))               // right finger moves up, around the left one
    guard case .rotate(_, .began) = s.actions.first else { Issue.record("expected rotate, got \(s.actions)"); return }
}

// MARK: one-finger drag mode

@Test func inScrollModeAOneFingerPanScrollsWithMomentum() throws {
    var s = Script(oneFingerDrag: .scroll)
    s.at(0, began(0, 0.5, 0.5))
    s.at(30, moved(0, 0.5, 0.5 + mmY(5)))
    s.at(40, moved(0, 0.5, 0.5 + mmY(9)))
    s.at(50, ended(0, 0.5, 0.5 + mmY(9)))
    guard case let .scroll(_, dy0, .began) = s.actions.first else { Issue.record("expected scroll began, got \(s.actions)"); return }
    #expect(abs(dy0 - mmY(5)) < 1e-9, "the began event carries the movement since touch-down")
    guard case let .scroll(_, dy1, .changed) = s.actions[1] else { Issue.record("expected scroll changed"); return }
    #expect(abs(dy1 - mmY(4)) < 1e-9)
    guard case let .scrollEnded(_, vy) = try #require(s.actions.last) else { Issue.record("expected scrollEnded"); return }
    #expect(vy > 0)
}

@Test func inScrollModeHoldThenMoveIsStillClickAndDrag() {
    var s = Script(oneFingerDrag: .scroll)
    s.at(0, began(0, 0.3, 0.3))
    s.at(600, moved(0, 0.3 + mmX(5), 0.3))
    #expect(s.actions.first == .dragBegan(at: PanelPoint(x: 0.3, y: 0.3), hold: true))
}

@Test func inScrollModeAPanStartingOnATitleBarMovesTheWindow() {
    var s = Script(oneFingerDrag: .scroll)
    s.recognizer.dragZone = { _ in true }
    s.at(0, began(0, 0.3, 0.3))
    s.at(50, moved(0, 0.3 + mmX(5), 0.3))
    #expect(s.actions.first == .dragBegan(at: PanelPoint(x: 0.3, y: 0.3), hold: false))
}

@Test func scrollModeIsTheDefault() {
    #expect(GestureConfig().oneFingerDrag == .scroll)
}


// MARK: three-finger drag (like the trackpad setting)

@Test func threeFingersMovingTogetherDragFromTheirCentre() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.5))
    s.at(30, began(1, 0.5, 0.5))
    s.at(60, began(2, 0.6, 0.5))
    s.at(100, moved(0, 0.4, 0.5 + mmY(6)), moved(1, 0.5, 0.5 + mmY(6)), moved(2, 0.6, 0.5 + mmY(6)))
    #expect(s.actions.count == 2)
    #expect(isDragBegan(s.actions.first, near: PanelPoint(x: 0.5, y: 0.5), hold: true))
    #expect(isDragMoved(s.actions.last, near: PanelPoint(x: 0.5, y: 0.5 + mmY(6))))
    s.at(150, ended(1, 0.5, 0.5 + mmY(6)))
    #expect(isDragEnded(s.actions.last, near: PanelPoint(x: 0.5, y: 0.5 + mmY(6))), "the drag ends when the fingers lift")
    let count = s.actions.count
    s.at(170, ended(0, 0.4, 0.5 + mmY(6)), ended(2, 0.6, 0.5 + mmY(6)))
    #expect(s.actions.count == count)
}

@Test func theThreeFingerDragPointCanBeTheFirstFinger() {
    var s = Script { $0.threeFingerAnchor = .firstFinger }
    s.at(0, began(0, 0.4, 0.5))
    s.at(30, began(1, 0.5, 0.5))
    s.at(60, began(2, 0.6, 0.5))
    s.at(100, moved(0, 0.4, 0.5 + mmY(6)), moved(1, 0.5, 0.5 + mmY(6)), moved(2, 0.6, 0.5 + mmY(6)))
    #expect(s.actions.count == 2)
    #expect(isDragBegan(s.actions.first, near: PanelPoint(x: 0.4, y: 0.5), hold: true))
    #expect(isDragMoved(s.actions.last, near: PanelPoint(x: 0.4, y: 0.5 + mmY(6))))
}

@Test func threeFingersThatDoNotMoveDoNothing() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.5), began(1, 0.5, 0.5), began(2, 0.6, 0.5))
    s.at(120, ended(0, 0.4, 0.5), ended(1, 0.5, 0.5), ended(2, 0.6, 0.5))
    #expect(s.actions.isEmpty)
}

@Test func aThirdFingerDuringATwoFingerScrollIsStillIgnored() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4), began(1, 0.5, 0.4))
    s.at(30, moved(0, 0.4, 0.4 + mmY(6)), moved(1, 0.5, 0.4 + mmY(6)))   // scroll locks
    s.at(60, began(2, 0.6, 0.4 + mmY(6)))
    s.at(80, moved(0, 0.4, 0.4 + mmY(9)), moved(1, 0.5, 0.4 + mmY(9)), moved(2, 0.6, 0.4 + mmY(9)))
    #expect(!s.actions.contains { if case .dragBegan = $0 { true } else { false } })
    guard case .scroll(_, _, .changed) = s.actions.last else { Issue.record("scroll should continue, got \(s.actions)"); return }
}

@Test func aThirdFingerArrivingLateLeavesTheTwoFingerGesture() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.4))
    s.at(30, began(1, 0.5, 0.4))
    s.at(400, began(2, 0.6, 0.4))
    s.at(440, moved(0, 0.4, 0.4 + mmY(6)), moved(1, 0.5, 0.4 + mmY(6)), moved(2, 0.6, 0.4 + mmY(6)))
    guard case .scroll(_, _, .began) = s.actions.first else { Issue.record("expected the two-finger scroll, got \(s.actions)"); return }
}

@Test func withThreeFingerDragOffThreeFingersBehaveAsBefore() {
    var s = Script { $0.threeFingerDrag = false }
    s.at(0, began(0, 0.4, 0.4), began(1, 0.5, 0.4), began(2, 0.6, 0.4))
    s.at(40, moved(0, 0.4, 0.4 + mmY(6)), moved(1, 0.5, 0.4 + mmY(6)), moved(2, 0.6, 0.4 + mmY(6)))
    guard case .scroll(_, _, .began) = s.actions.first else { Issue.record("expected the two-finger scroll, got \(s.actions)"); return }
}

@Test func aPalmDuringAThreeFingerDragEndsIt() {
    var s = Script()
    s.at(0, began(0, 0.4, 0.5), began(1, 0.5, 0.5), began(2, 0.6, 0.5))
    s.at(40, moved(0, 0.4, 0.5 + mmY(6)), moved(1, 0.5, 0.5 + mmY(6)), moved(2, 0.6, 0.5 + mmY(6)))
    s.at(60, began(3, 0.7, 0.7))
    #expect(isDragEnded(s.actions.last, near: PanelPoint(x: 0.5, y: 0.5 + mmY(6))))
}

// MARK: rest a finger, add two (owner's choice 2026-10-11: the drag grabs exactly under the resting finger)

@Test func restingAFingerThenAddingTwoDragsFromTheRestingFinger() {
    // The owner's settings: one-finger drag scrolls, three-finger drag grabs at the centre of the fingers.
    // Before, the late fingers were ignored and the first finger's move scrolled.
    var s = Script(oneFingerDrag: .scroll)
    s.at(0, began(0, 0.3, 0.5))
    s.at(250, began(1, 0.45, 0.55))
    s.at(300, began(2, 0.5, 0.55))
    s.at(350, moved(0, 0.3, 0.5 + mmY(6)), moved(1, 0.45, 0.55 + mmY(6)), moved(2, 0.5, 0.55 + mmY(6)))
    #expect(s.actions.count == 2)
    #expect(isDragBegan(s.actions.first, near: PanelPoint(x: 0.3, y: 0.5), hold: true))
    #expect(isDragMoved(s.actions.last, near: PanelPoint(x: 0.3, y: 0.5 + mmY(6))))
    s.at(400, ended(0, 0.3, 0.5 + mmY(6)), ended(1, 0.45, 0.55 + mmY(6)), ended(2, 0.5, 0.55 + mmY(6)))
    #expect(isDragEnded(s.actions.last, near: PanelPoint(x: 0.3, y: 0.5 + mmY(6))))
}

// Owner's pick 2026-10-11: grab where the resting finger first touched, not where it rolled to.
@Test func theRestingFingerGrabsWhereItFirstTouched() {
    var s = Script(oneFingerDrag: .scroll)
    s.at(0, began(0, 0.3, 0.5))
    s.at(150, moved(0, 0.3 + mmX(2), 0.5))   // the finger rolls 2 mm (within the tap slop) as the others land
    s.at(250, began(1, 0.45, 0.55))
    s.at(300, began(2, 0.5, 0.55))
    s.at(350, moved(0, 0.3 + mmX(2), 0.5 + mmY(6)), moved(1, 0.45, 0.55 + mmY(6)), moved(2, 0.5, 0.55 + mmY(6)))
    #expect(isDragBegan(s.actions.first, near: PanelPoint(x: 0.3, y: 0.5), hold: true), "where it first touched")
    #expect(isDragMoved(s.actions.last, near: PanelPoint(x: 0.3, y: 0.5 + mmY(6))), "then moves with the hand, without jumping by the roll")
}

@Test func restingThenAddingTwoWithoutMovingDoesNothing() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.5))
    s.at(300, began(1, 0.45, 0.55), began(2, 0.5, 0.55))
    s.at(900, ended(1, 0.45, 0.55), ended(2, 0.5, 0.55))
    s.at(950, ended(0, 0.3, 0.5))
    #expect(s.actions.isEmpty, "no tap, no right-click")
}

@Test func oneLateFingerIsStillIgnored() {
    var s = Script()
    s.at(0, began(0, 0.3, 0.5))
    s.at(200, began(1, 0.45, 0.55))
    s.at(300, ended(1, 0.45, 0.55))
    s.at(350, ended(0, 0.3, 0.5))
    #expect(s.actions == [.tap(at: PanelPoint(x: 0.3, y: 0.5), count: 1)])
}

@Test func twoFingersAddedAfterTheRestWindowAreIgnoredAsBefore() {
    var s = Script(oneFingerDrag: .scroll)
    s.at(0, began(0, 0.3, 0.5))
    s.at(1_600, began(1, 0.45, 0.55), began(2, 0.5, 0.55))
    s.at(1_700, ended(1, 0.45, 0.55), ended(2, 0.5, 0.55))
    s.at(1_750, ended(0, 0.3, 0.5))
    #expect(s.actions == [.rightClick(at: PanelPoint(x: 0.3, y: 0.5))], "a long press")
}

@Test func withThreeFingerDragOffRestingThenAddingTwoBehavesAsBefore() {
    var s = Script { $0.threeFingerDrag = false }
    s.at(0, began(0, 0.3, 0.5))
    s.at(300, began(1, 0.45, 0.55), began(2, 0.5, 0.55))
    s.at(350, ended(1, 0.45, 0.55), ended(2, 0.5, 0.55))
    s.at(400, ended(0, 0.3, 0.5))
    #expect(s.actions == [.tap(at: PanelPoint(x: 0.3, y: 0.5), count: 1)])
}

// Centroids of three coordinates can differ from the exact value in the last binary digit.
private func near(_ a: PanelPoint, _ b: PanelPoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
private func isDragBegan(_ action: GestureAction?, near p: PanelPoint, hold: Bool) -> Bool {
    if case let .dragBegan(at, h) = action { return h == hold && near(at, p) }
    return false
}
private func isDragMoved(_ action: GestureAction?, near p: PanelPoint) -> Bool {
    if case let .dragMoved(to) = action { return near(to, p) }
    return false
}
private func isDragEnded(_ action: GestureAction?, near p: PanelPoint) -> Bool {
    if case let .dragEnded(at) = action { return near(at, p) }
    return false
}

// MARK: gestures switched off (trackpad settings)

@Test func withPinchOffSpreadingFingersDoesNotZoom() {
    var s = Script { $0.pinchEnabled = false }
    s.at(0, began(0, 0.45, 0.5), began(1, 0.55, 0.5))
    s.at(30, moved(0, 0.43, 0.5), moved(1, 0.57, 0.5))
    s.at(60, ended(0, 0.43, 0.5), ended(1, 0.57, 0.5))
    #expect(!s.actions.contains { if case .magnify = $0 { true } else { false } })
}

@Test func withRotateOffTwistingDoesNotRotate() {
    var s = Script { $0.rotateEnabled = false }
    s.at(0, began(0, 0.5 - mmX(20), 0.5), began(1, 0.5 + mmX(20), 0.5))
    s.at(30, moved(0, 0.5 - mmX(20), 0.5 + mmY(5)), moved(1, 0.5 + mmX(20), 0.5 - mmY(5)))
    #expect(!s.actions.contains { if case .rotate = $0 { true } else { false } })
}

@Test func withScrollOffTwoFingersMovingTogetherDoNotScroll() {
    var s = Script { $0.scrollEnabled = false }
    s.at(0, began(0, 0.4, 0.4), began(1, 0.5, 0.4))
    s.at(30, moved(0, 0.4, 0.4 + mmY(10)), moved(1, 0.5, 0.4 + mmY(10)))
    #expect(s.actions.isEmpty)
}

// MARK: four-/five-finger dock swipes and the Notification Center edge swipe

private func fourDown(_ s: inout Script, at y: Double = 0.5, spread: Double = 0.05) {
    s.at(0, began(0, 0.4, y), began(1, 0.4 + spread, y), began(2, 0.4 + 2 * spread, y))
    s.at(60, began(3, 0.4 + 3 * spread, y + 0.08))
}

private func dockSwipes(_ actions: [GestureAction]) -> [(kind: DockSwipeKind, delta: Double, phase: GesturePhase)] {
    actions.compactMap { if case let .dockSwipe(kind, delta, phase) = $0 { (kind, delta, phase) } else { nil } }
}

private func moveAll(_ s: inout Script, _ t: UInt64, ids: [UInt8], from start: [(Double, Double)], dx: Double, dy: Double) {
    let events = zip(ids, start).map { moved($0.0, $0.1.0 + dx, $0.1.1 + dy) }
    s.recognizer.handle(events, atNs: t * ms).forEach { s.actions.append($0) }
}

private let fourStart: [(Double, Double)] = [(0.4, 0.5), (0.45, 0.5), (0.5, 0.5), (0.55, 0.58)]

@Test func fourFingersSwipingUpOpenMissionControl() {
    var s = Script()
    fourDown(&s)
    moveAll(&s, 100, ids: [0, 1, 2, 3], from: fourStart, dx: 0, dy: -mmY(10))
    moveAll(&s, 120, ids: [0, 1, 2, 3], from: fourStart, dx: 0, dy: -mmY(20))
    s.at(140, ended(0, 0.4, 0.5 - mmY(20)))
    let swipes = dockSwipes(s.actions)
    #expect(swipes.first?.kind == .vertical && swipes.first?.phase == .began)
    #expect(swipes.filter { $0.phase != .ended }.allSatisfy { $0.delta > 0 }, "up = positive = Mission Control")
    #expect(swipes.last?.phase == .ended)
}

@Test func fourFingersSwipingDownOpenAppExpose() {
    var s = Script()
    fourDown(&s)
    moveAll(&s, 100, ids: [0, 1, 2, 3], from: fourStart, dx: 0, dy: mmY(15))
    let swipes = dockSwipes(s.actions)
    #expect(swipes.first?.kind == .vertical)
    #expect((swipes.first?.delta ?? 0) < 0)
}

@Test func fourFingersSwipingLeftMoveToTheSpaceOnTheRight() {
    var s = Script()
    fourDown(&s)
    moveAll(&s, 100, ids: [0, 1, 2, 3], from: fourStart, dx: -mmX(15), dy: 0)
    let swipes = dockSwipes(s.actions)
    #expect(swipes.first?.kind == .horizontal)
    #expect((swipes.first?.delta ?? 0) > 0, "content follows the fingers: left = next Space on the right")
}

@Test func thumbAndFingersPinchingInOpenLaunchpad() {
    var s = Script()
    fourDown(&s, spread: 0.08)
    // Fingers move toward their centre (about 0.52, 0.52) by 40 %.
    let start: [(Double, Double)] = [(0.4, 0.5), (0.48, 0.5), (0.56, 0.5), (0.64, 0.58)]
    let centre = (x: start.map(\.0).reduce(0, +) / 4, y: start.map(\.1).reduce(0, +) / 4)
    let events = zip([UInt8(0), 1, 2, 3], start).map { moved($0.0, $0.1.0 + (centre.x - $0.1.0) * 0.4, $0.1.1 + (centre.y - $0.1.1) * 0.4) }
    s.actions += s.recognizer.handle(events, atNs: 100 * ms)
    let swipes = dockSwipes(s.actions)
    #expect(swipes.first?.kind == .pinch)
    #expect((swipes.first?.delta ?? 0) > 0, "pinch in = positive = Launchpad")
}

@Test func withMissionControlSwipeOffFourFingersDoNothingVertically() {
    var s = Script { $0.fourFingerVerticalSwipe = false }
    fourDown(&s)
    moveAll(&s, 100, ids: [0, 1, 2, 3], from: fourStart, dx: 0, dy: -mmY(20))
    #expect(dockSwipes(s.actions).isEmpty)
}

@Test func aSixthFingerCancelsADockSwipe() {
    var s = Script()
    fourDown(&s)
    moveAll(&s, 100, ids: [0, 1, 2, 3], from: fourStart, dx: 0, dy: -mmY(15))
    s.at(120, began(4, 0.2, 0.2), began(5, 0.25, 0.2))
    #expect(s.actions.last == .dockSwipeCancelled(.vertical), "a palm must not complete Mission Control")
}

@Test func twoFingersFromTheRightEdgeMovingLeftOpenNotificationCenter() {
    var s = Script()
    s.at(0, began(0, 0.99, 0.4), began(1, 0.995, 0.5))
    s.at(40, moved(0, 0.99 - mmX(15), 0.4), moved(1, 0.995 - mmX(15), 0.5))
    s.at(60, moved(0, 0.99 - mmX(25), 0.4), moved(1, 0.995 - mmX(25), 0.5))
    #expect(s.actions == [.notificationCenter])
}

@Test func withTheEdgeSwipeOffTwoFingersAtTheEdgeScroll() {
    var s = Script { $0.notificationCenterSwipe = false }
    s.at(0, began(0, 0.99, 0.4), began(1, 0.995, 0.5))
    s.at(40, moved(0, 0.99 - mmX(15), 0.4), moved(1, 0.995 - mmX(15), 0.5))
    guard case .scroll(_, _, .began) = s.actions.first else { Issue.record("expected a scroll, got \(s.actions)"); return }
}

// A hand settling: four contacts, one slides far, the others barely move. Must not open Mission Control.
@Test func aHandSettlingDoesNotTriggerASystemGesture() {
    var s = Script()
    fourDown(&s)
    s.at(100, moved(0, 0.4, 0.5 - mmY(40)), moved(1, 0.45, 0.5 - mmY(1)), moved(2, 0.5, 0.5), moved(3, 0.55, 0.58 + mmY(1)))
    s.at(140, moved(0, 0.4, 0.5 - mmY(48)))
    #expect(dockSwipes(s.actions).isEmpty)
}

// Owner report: Notification Center was hard to trigger. Real attempts: fingers stacked vertically a little
// inside the edge, moving left unevenly, ended up as rotate or scroll.
@Test func anUnevenEdgeSwipeStartingAFewMillimetresInStillOpensNotificationCenter() {
    var s = Script()
    let x = 1 - mmX(10)   // 10 mm in from the right edge
    s.at(0, began(0, x, 0.40), began(1, x, 0.47))
    s.at(40, moved(0, x - mmX(9), 0.40), moved(1, x - mmX(4), 0.47))
    s.at(70, moved(0, x - mmX(16), 0.40), moved(1, x - mmX(9), 0.47))
    #expect(s.actions.contains(.notificationCenter))
    #expect(!s.actions.contains { if case .rotate = $0 { true } else { false } })
}
