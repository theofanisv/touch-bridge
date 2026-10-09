import Testing
@testable import TouchCore

@Test func windowLocationIsTheGlobalPointRelativeToTheWindowsTopLeft() {
    let window = ScreenRect(x: 2238, y: 212, width: 900, height: 628)
    #expect(DirectAddressing.windowLocation(of: ScreenPoint(x: 2488, y: 662), in: window) == ScreenPoint(x: 250, y: 450))
}

@Test func windowLocationOfTheWindowOriginIsZero() {
    let window = ScreenRect(x: -1200, y: 40, width: 800, height: 600)
    #expect(DirectAddressing.windowLocation(of: ScreenPoint(x: -1200, y: 40), in: window) == ScreenPoint(x: 0, y: 0))
}
