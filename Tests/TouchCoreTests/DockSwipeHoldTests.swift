import Testing
@testable import TouchCore

@Test func withoutAHoldStepsPassStraightThrough() {
    var hold = DockSwipeHold()
    #expect(hold.pass(0.2, .began).map(\.delta) == [0.2])
    #expect(hold.pass(0.1, .changed).map(\.phase) == [.changed])
}

@Test func heldStepsAreReleasedAsOneBeganWithTheirSum() {
    var hold = DockSwipeHold()
    hold.start()
    #expect(hold.pass(0.2, .began).isEmpty)
    #expect(hold.pass(0.1, .changed).isEmpty)
    #expect(hold.pass(0.05, .changed).isEmpty)
    let released = hold.release()
    #expect(released.count == 1)
    #expect(released.first?.phase == .began)
    #expect(abs((released.first?.delta ?? 0) - 0.35) < 1e-9)
    #expect(hold.pass(0.1, .changed).map(\.delta) == [0.1], "after the release, steps flow again")
}

@Test func fingersLiftedDuringTheHoldReleaseBeganThenEnded() {
    var hold = DockSwipeHold()
    hold.start()
    _ = hold.pass(0.6, .began)
    _ = hold.pass(0, .ended)
    #expect(hold.release().map(\.phase) == [.began, .ended])
}

@Test func aCancelDuringTheHoldDropsEverything() {
    var hold = DockSwipeHold()
    hold.start()
    _ = hold.pass(0.3, .began)
    #expect(hold.cancel() == true, "nothing reached the system, so nothing needs cancelling")
    #expect(hold.release().isEmpty)
    #expect(hold.cancel() == false)
}
