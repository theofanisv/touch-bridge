import Testing
@testable import TouchCore

private let ms: UInt64 = 1_000_000

// Owner report 2026-10-11: a Space switch on the touch display took focus away from the MacBook window.
@Test func whenTheSwitchMovesFocusAwayItIsGivenBack() {
    let keeper = FocusKeeper(pid: 501, startedNs: 0)
    #expect(keeper.poll(frontmost: 501, atNs: 100 * ms) == .wait)
    #expect(keeper.poll(frontmost: 777, atNs: 400 * ms) == .restore(501))
}

@Test func ifFocusNeverMovesTheKeeperStopsAfterOneAndAHalfSeconds() {
    let keeper = FocusKeeper(pid: 501, startedNs: 0)
    #expect(keeper.poll(frontmost: 501, atNs: 1_400 * ms) == .wait)
    #expect(keeper.poll(frontmost: 501, atNs: 1_500 * ms) == .stop)
}

@Test func anUnknownFrontmostAppIsNotAChange() {
    let keeper = FocusKeeper(pid: 501, startedNs: 0)
    #expect(keeper.poll(frontmost: nil, atNs: 200 * ms) == .wait)
}
