import Testing
@testable import TouchCore

private let s: UInt64 = 1_000_000_000

@Test func aMouseReportAsksThePanelForMultitouch() {
    var watch = PanelModeWatch()
    #expect(watch.observe(.mouse, atNs: 0) == .requestMultitouch)
}

@Test func requestsAreRateLimited() {
    var watch = PanelModeWatch()
    _ = watch.observe(.mouse, atNs: 0)
    #expect(watch.observe(.mouse, atNs: 1 * s) == nil)
    #expect(watch.observe(.mouse, atNs: 6 * s) == .requestMultitouch)
}

@Test func theSwitchBackToMultitouchIsReportedOnce() {
    var watch = PanelModeWatch()
    _ = watch.observe(.mouse, atNs: 0)
    #expect(watch.observe(.digitizer, atNs: 1 * s) == .multitouchRestored)
    #expect(watch.observe(.digitizer, atNs: 2 * s) == nil)
}

@Test func multitouchFromTheStartNeedsNothing() {
    var watch = PanelModeWatch()
    #expect(watch.observe(.digitizer, atNs: 0) == nil)
    #expect(watch.observe(.digitizer, atNs: s) == nil)
}
