import Testing
@testable import TouchCore

private let macbook = ScreenRect(x: 0, y: 0, width: 1728, height: 1117)
private let arzopa = ScreenRect(x: 1728, y: 0, width: 1920, height: 1080)

@Test func theClockKeepsItsDistanceFromTheRightEdgeOnAnotherDisplay() {
    // Clock 90 pt from the MacBook's right edge, 12 pt below its top.
    let clock = ScreenPoint(x: 1728 - 90, y: 12)
    #expect(MenuBarGeometry.sameStatusItem(as: clock, on: macbook, in: arzopa) == ScreenPoint(x: 3648 - 90, y: 12))
}

@Test func onTheSameDisplayThePointIsUnchanged() {
    let clock = ScreenPoint(x: 3550, y: 11)
    #expect(MenuBarGeometry.sameStatusItem(as: clock, on: arzopa, in: arzopa) == clock)
}

@Test func displaysBelowOrAboveKeepTheOffsetFromTheirOwnTop() {
    let below = ScreenRect(x: 0, y: 1117, width: 1920, height: 1080)
    #expect(MenuBarGeometry.sameStatusItem(as: ScreenPoint(x: 1638, y: 12), on: macbook, in: below) == ScreenPoint(x: 1830, y: 1129))
}

@Test func aRectContainsItsTopLeftEdgeButNotItsBottomRight() {
    #expect(arzopa.contains(ScreenPoint(x: 1728, y: 0)))
    #expect(!arzopa.contains(ScreenPoint(x: 3648, y: 500)))
    #expect(!macbook.contains(ScreenPoint(x: 1728, y: 10)))
}

@Test func fromTheTallerNotchMenuBarTheClickStaysInsideAStandardMenuBar() {
    // MacBook menu bar is 38 pt (notch); the clock's centre there is about 19 pt down, the ARZOPA's bar is 24 pt.
    let p = MenuBarGeometry.sameStatusItem(as: ScreenPoint(x: 1638, y: 19), on: macbook, in: arzopa)
    #expect(p == ScreenPoint(x: 3558, y: 12))
}
