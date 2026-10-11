import Testing
@testable import TouchCore

private let s: UInt64 = 1_000_000_000
private let ms: UInt64 = 1_000_000

@Test func theDockGoesBackOnceLaunchpadHasClosed() {
    var watch = DockReturnWatch(startedNs: 0)
    #expect(watch.poll(launchpadOpen: true, fingersDown: false, atNs: 250 * ms) == .wait)
    #expect(watch.poll(launchpadOpen: true, fingersDown: true, atNs: 4 * s) == .wait, "the owner taps around in Launchpad")
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 5 * s) == .wait, "one closed poll could be a flicker")
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 5 * s + 250 * ms) == .pushBack)
}

@Test func aFlickerOfLaunchpadDoesNotCountAsClosed() {
    var watch = DockReturnWatch(startedNs: 0)
    _ = watch.poll(launchpadOpen: true, fingersDown: false, atNs: 250 * ms)
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 500 * ms) == .wait)
    #expect(watch.poll(launchpadOpen: true, fingersDown: false, atNs: 750 * ms) == .wait)
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 1 * s) == .wait)
}

@Test func ifLaunchpadNeverOpensTheDockStillGoesBackAfterTwoSeconds() {
    var watch = DockReturnWatch(startedNs: 0)
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 1 * s) == .wait)
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 2 * s) == .pushBack)
}

@Test func theDockWaitsUntilTheFingersAreOffThePanel() {
    var watch = DockReturnWatch(startedNs: 0)
    _ = watch.poll(launchpadOpen: true, fingersDown: false, atNs: 250 * ms)
    _ = watch.poll(launchpadOpen: false, fingersDown: true, atNs: 500 * ms)
    #expect(watch.poll(launchpadOpen: false, fingersDown: true, atNs: 750 * ms) == .wait, "the cursor is busy with a touch")
    #expect(watch.poll(launchpadOpen: false, fingersDown: false, atNs: 1 * s) == .pushBack)
}

@Test func theWatchGivesUpAfterTenMinutes() {
    var watch = DockReturnWatch(startedNs: 0)
    _ = watch.poll(launchpadOpen: true, fingersDown: false, atNs: 250 * ms)
    #expect(watch.poll(launchpadOpen: true, fingersDown: false, atNs: 600 * s) == .stop)
}

private let macbook = ScreenRect(x: 0, y: 0, width: 1728, height: 1117)
private let arzopa = ScreenRect(x: 1728, y: 0, width: 1920, height: 1080)

// Owner report 2026-10-11: with the Dock already on the touch display, "then back" never sent it back.
@Test func thenBackReturnsTheDockEvenWhenItWasAlreadyOnTheTouchDisplay() {
    let plan = LaunchpadDock.plan(mode: .bringDockAndReturn, pinchInward: true, dockOnTouchDisplay: true)
    #expect(plan == LaunchpadDock.Plan(bringDock: false, returnDock: true))
}

@Test func eachModePlansItsMoves() {
    #expect(LaunchpadDock.plan(mode: .bringDock, pinchInward: true, dockOnTouchDisplay: false) == .init(bringDock: true, returnDock: false))
    #expect(LaunchpadDock.plan(mode: .bringDock, pinchInward: true, dockOnTouchDisplay: true) == .init(bringDock: false, returnDock: false))
    #expect(LaunchpadDock.plan(mode: .bringDockAndReturn, pinchInward: true, dockOnTouchDisplay: false) == .init(bringDock: true, returnDock: true))
    #expect(LaunchpadDock.plan(mode: .leave, pinchInward: true, dockOnTouchDisplay: false) == .init(bringDock: false, returnDock: false))
    #expect(LaunchpadDock.plan(mode: .bringDockAndReturn, pinchInward: false, dockOnTouchDisplay: true) == .init(bringDock: false, returnDock: false), "spreading = Show Desktop")
}

@Test func theDocksHomeIsWhereItCameFrom() {
    let dock = ScreenPoint(x: 864, y: 1116)   // auto-hidden at the MacBook's bottom edge
    #expect(LaunchpadDock.home(dock: dock, touch: arzopa, displays: [macbook, arzopa], main: macbook) == macbook)
}

@Test func aDockFoundOnTheTouchDisplayGoesHomeToTheMainDisplay() {
    let dock = ScreenPoint(x: 2688, y: 1079)
    #expect(LaunchpadDock.home(dock: dock, touch: arzopa, displays: [macbook, arzopa], main: macbook) == macbook)
}

@Test func whenTheTouchDisplayIsTheMainOneTheDockGoesToAnother() {
    let dock = ScreenPoint(x: 2688, y: 1079)
    #expect(LaunchpadDock.home(dock: dock, touch: arzopa, displays: [arzopa, macbook], main: arzopa) == macbook)
    #expect(LaunchpadDock.home(dock: dock, touch: arzopa, displays: [arzopa], main: arzopa) == nil, "nowhere else to go")
}
