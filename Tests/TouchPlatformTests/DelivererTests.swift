import CoreGraphics
import Foundation
import Testing
@testable import TouchCore
@testable import TouchPlatform

/// Records what the deliverer does instead of touching the window server.
final class FakeEffects: DeliveryEffects, @unchecked Sendable {
    var posted: [(type: CGEventType, location: CGPoint, scrollPhase: Int64, momentumPhase: Int64, target: Deliverer.Target)] = []
    var cursor = CGPoint(x: 100, y: 100)   // starts on the MacBook screen
    var hidden = false
    var activated: [pid_t] = []
    var frontmost: pid_t? = 1
    var press: (pid: Int32, right: Bool)?

    func post(_ event: CGEvent, to target: Deliverer.Target) {
        posted.append((event.type, event.location,
                       event.getIntegerValueField(CGEventField(rawValue: 99)!),
                       event.getIntegerValueField(CGEventField(rawValue: 123)!), target))
    }
    func cursorLocation() -> CGPoint? { cursor }
    func warpCursor(to point: CGPoint) { cursor = point }
    func reassociateCursor() {}
    func hideCursor() { hidden = true }
    func showCursor() { hidden = false }
    func frontmostApp() -> pid_t? { frontmost }
    func activate(_ pid: pid_t) { activated.append(pid); frontmost = pid }
    func recordPress(pid: Int32, right: Bool) { press = (pid, right) }
    func clearPress() { press = nil }
    func pendingPress() -> (pid: Int32, right: Bool)? { press }
}

private let arzopaPoint = CGPoint(x: 2500, y: 500)
private let direct = Deliverer.Target.direct(DirectTarget(pid: 42, window: 7, origin: CGPoint(x: 2000, y: 100)))

private func make() -> (Deliverer, FakeEffects, DispatchQueue) {
    let queue = DispatchQueue(label: "deliverer-test")
    let effects = FakeEffects()
    return (Deliverer(queue: queue, effects: effects), effects, queue)
}

// Review finding 1: a Direct gesture that interrupts a Warp scroll's momentum left the cursor hidden.
@Test func aDirectGestureAfterWarpMomentumGivesTheCursorBack() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(.warp, at: arzopaPoint, appPID: 42, activate: false)
        d.scroll(dx: 0, dy: 10, phase: .began)
        d.scrollEnded(velocityX: 0, velocityY: 3000)   // momentum running, cursor parked at the finger
        d.begin(direct, at: arzopaPoint, appPID: 42, activate: true)
    }
    #expect(fx.hidden == false)
    #expect(fx.cursor == CGPoint(x: 100, y: 100), "back where it was on the MacBook screen")
}

@Test func aWarpTapReturnsTheCursorShortlyAfter() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(.warp, at: arzopaPoint, appPID: 42, activate: true)
        d.click(at: arzopaPoint, count: 1, button: .left)
        d.end()
    }
    #expect(fx.hidden == true, "stays at the finger for a moment")
    Thread.sleep(forTimeInterval: Deliverer.warpReturnDelay + 0.1)
    queue.sync {}
    #expect(fx.hidden == false)
    #expect(fx.cursor == CGPoint(x: 100, y: 100))
}

// Launchpad and Space switching open where the cursor is: it waits on the touch display until the animation is under way.
@Test func aSystemGestureKeepsTheCursorParkedForTheRequestedTime() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(.warp, at: arzopaPoint, appPID: nil, activate: false)
        d.end(returnDelay: 0.4)
    }
    Thread.sleep(forTimeInterval: Deliverer.warpReturnDelay + 0.1)
    queue.sync {}
    #expect(fx.hidden == true)
    #expect(fx.cursor == arzopaPoint, "still on the touch display")
    Thread.sleep(forTimeInterval: 0.4)
    queue.sync {}
    #expect(fx.hidden == false)
    #expect(fx.cursor == CGPoint(x: 100, y: 100))
    #expect(fx.posted.isEmpty, "parking posts nothing")
}

// Launchpad opens where the Dock is; the Dock moves to a display when the cursor pushes against its bottom edge.
@Test func aNudgePushesTheParkedCursorThroughTheWindowServer() {
    let (d, fx, queue) = make()
    let edge = CGPoint(x: 2688, y: 1079)
    queue.sync {
        d.begin(.warp, at: edge, appPID: nil, activate: false)
        d.nudge(at: edge, dx: 0, dy: 4)
    }
    #expect(fx.posted.count == 1)
    #expect(fx.posted.first?.type == .mouseMoved)
    #expect(fx.posted.first?.location == edge)
    #expect(fx.posted.first?.target == .warp)
    #expect(fx.hidden == true, "the cursor stays hidden while it pushes")
}

@Test func aNudgeInDryRunPostsNothing() {
    let (d, fx, queue) = make()
    queue.sync {
        d.dryRun = true
        d.nudge(at: CGPoint(x: 2688, y: 1079), dx: 0, dy: 4)
    }
    #expect(fx.posted.isEmpty)
}

// Review findings 3 and 4: stopping or losing the display mid-gesture must close everything.
@Test func abortDuringAWarpDragReleasesTheButtonAndTheCursor() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(.warp, at: arzopaPoint, appPID: 42, activate: true)
        d.dragDown(at: arzopaPoint)
        d.dragMove(to: CGPoint(x: 2550, y: 520))
        d.abortGesture()
    }
    #expect(fx.posted.last?.type == .leftMouseUp)
    #expect(fx.press == nil)
    #expect(fx.hidden == false)
    #expect(fx.cursor == CGPoint(x: 100, y: 100))
}

@Test func abortDuringADirectScrollEndsTheScrollPhase() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(direct, at: arzopaPoint, appPID: 42, activate: false)
        d.scroll(dx: 0, dy: 5, phase: .began)
        d.abortGesture()
    }
    let last = fx.posted.last
    #expect(last?.type == .scrollWheel)
    #expect(last?.scrollPhase == 4, "kCGScrollPhaseEnded")
}

@Test func abortDuringMomentumStopsIt() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(direct, at: arzopaPoint, appPID: 42, activate: false)
        d.scroll(dx: 0, dy: 10, phase: .began)
        d.scrollEnded(velocityX: 0, velocityY: 3000)
        d.abortGesture()
    }
    let count = queue.sync { fx.posted.count }
    #expect(fx.posted.last?.momentumPhase == 3, "momentum end")
    Thread.sleep(forTimeInterval: 0.1)
    #expect(queue.sync { fx.posted.count } == count, "no momentum events after the abort")
}

@Test func abortDuringAPinchEndsIt() {
    let (d, fx, queue) = make()
    queue.sync {
        d.begin(direct, at: arzopaPoint, appPID: 42, activate: true)
        d.magnify(0.1, phase: .began)
        d.abortGesture()
    }
    #expect(fx.posted.count == 2, "began + ended")
}

@Test func abortWithNothingOpenDoesNothing() {
    let (d, fx, queue) = make()
    queue.sync { d.abortGesture() }
    #expect(fx.posted.isEmpty)
    #expect(fx.hidden == false)
}

// Trackpad setting "momentum scrolling" off: a flick ends without momentum.
@Test func withMomentumOffAFlickEndsWithoutMomentum() {
    let (d, fx, queue) = make()
    queue.sync {
        d.momentumEnabled = false
        d.begin(direct, at: arzopaPoint, appPID: 42, activate: false)
        d.scroll(dx: 0, dy: 10, phase: .began)
        d.scrollEnded(velocityX: 0, velocityY: 3000)
    }
    Thread.sleep(forTimeInterval: 0.05)
    #expect(queue.sync { fx.posted.allSatisfy { $0.momentumPhase == 0 } })
    #expect(fx.posted.last?.scrollPhase == 4)
}

// Owner's choice 2026-10-11: Launchpad by touch borrows the Dock and gives it back.
@Test func launchpadBringsTheDockOverThenBackByDefault() {
    #expect(PipelineSettings().launchpadDock == .bringDockAndReturn)
}

// Owner's choice 2026-10-11: a Space switch by touch keeps focus on the other display, as a setting.
@Test func aSpaceSwitchKeepsFocusByDefault() {
    #expect(PipelineSettings().keepFocusOnSpaceSwitch == true)
}
