import Testing
@testable import TouchCore

private func window(_ number: Int, pid: Int32 = 100, owner: String = "TextEdit", layer: Int = 0,
                    x: Double = 1800, y: Double = 100, w: Double = 800, h: Double = 600, alpha: Double = 1) -> WindowInfo {
    WindowInfo(number: number, pid: pid, ownerName: owner, layer: layer, bounds: ScreenRect(x: x, y: y, width: w, height: h), alpha: alpha)
}

private let inside = ScreenPoint(x: 2000, y: 400)

// MARK: hit testing (window list is front-to-back, as CGWindowListCopyWindowInfo returns it)

@Test func hitTestReturnsTheFrontmostWindowUnderThePoint() {
    let list = [window(1, x: 0, y: 0, w: 100, h: 100), window(2), window(3)]
    #expect(WindowHitTester.topWindow(at: inside, in: list, excludingPID: 999)?.number == 2)
}

@Test func hitTestSkipsOurOwnAndInvisibleWindows() {
    let list = [window(1, pid: 999), window(2, alpha: 0), window(3)]
    #expect(WindowHitTester.topWindow(at: inside, in: list, excludingPID: 999)?.number == 3)
}

@Test func hitTestFindsNothingOverEmptySpace() {
    #expect(WindowHitTester.topWindow(at: ScreenPoint(x: 5000, y: 5000), in: [window(1)], excludingPID: 999) == nil)
}

@Test func popupMenusAreDetectedByTheirWindowLayer() {
    #expect(WindowHitTester.popupMenuVisible(in: [window(1), window(2, layer: 101)]))
    #expect(!WindowHitTester.popupMenuVisible(in: [window(1)]))
}

// MARK: policy

private func context(_ kind: GestureKind, window w: WindowInfo? = window(1), point: ScreenPoint = inside,
                     popup: Bool = false, chromium: Bool = false, override: DeliveryMode? = nil, windowDrag: Bool = false) -> DeliveryContext {
    DeliveryContext(kind: kind, window: w, point: point, popupMenuVisible: popup, appIsChromium: chromium, appOverride: override,
                    startsWindowDrag: windowDrag)
}

@Test func ordinaryGesturesOnAnAppWindowGoDirect() {
    let policy = DeliveryPolicy()
    for kind: GestureKind in [.tap, .rightClick, .drag(hold: false), .scroll, .magnify, .rotate] {
        #expect(policy.decide(context(kind)) == .direct, "\(kind)")
    }
}

@Test func holdDragAlwaysWarpsEvenWithADirectOverride() {
    #expect(DeliveryPolicy().decide(context(.drag(hold: true), override: .direct)) == .warp)
}

@Test func perAppOverrideWinsOverAutomaticRules() {
    #expect(DeliveryPolicy().decide(context(.tap, override: .warp)) == .warp)
    #expect(DeliveryPolicy().decide(context(.tap, chromium: true, override: .direct)) == .direct)
}

@Test func chromiumBasedAppsWarp() {
    #expect(DeliveryPolicy().decide(context(.tap, chromium: true)) == .warp)
}

@Test func systemUIWarps() {
    for owner in ["Dock", "SystemUIServer", "Control Center", "Notification Center", "Spotlight", "Window Server"] {
        #expect(DeliveryPolicy().decide(context(.tap, window: window(1, owner: owner))) == .warp, "\(owner)")
    }
}

@Test func onlyNormalAndFloatingLayersGoDirect() {
    #expect(DeliveryPolicy().decide(context(.tap, window: window(1, layer: 3))) == .direct)
    #expect(DeliveryPolicy().decide(context(.tap, window: window(1, layer: 25))) == .warp)
}

@Test func anOpenPopupMenuOrNoWindowWarps() {
    #expect(DeliveryPolicy().decide(context(.tap, popup: true)) == .warp)
    #expect(DeliveryPolicy().decide(context(.tap, window: nil)) == .warp)
}

// Window moves are performed by the window server following the real cursor, so they need Warp.
// Whether a drag moves the window is decided by WindowDragRules (toolbar, title bar, title text).
@Test func dragsThatMoveAWindowWarpButOtherDragsGoDirect() {
    #expect(DeliveryPolicy().decide(context(.drag(hold: false), windowDrag: true)) == .warp)
    #expect(DeliveryPolicy().decide(context(.tap, windowDrag: true)) == .direct, "a tap on a title bar or toolbar is still a click")
    #expect(DeliveryPolicy().decide(context(.drag(hold: false))) == .direct)
    // The old fixed 28 pt band no longer decides on its own.
    #expect(DeliveryPolicy().decide(context(.drag(hold: false), point: ScreenPoint(x: 2000, y: 110))) == .direct)
}

@Test func pinchAndRotateFollowTheGesturesDirectSetting() {
    var policy = DeliveryPolicy()
    policy.gesturesDirect = false
    #expect(policy.decide(context(.magnify)) == .warp)
    #expect(policy.decide(context(.rotate)) == .warp)
    #expect(policy.decide(context(.scroll)) == .direct)
}

@Test func aForcedModeOverridesEverything() {
    var policy = DeliveryPolicy()
    policy.forced = .direct
    #expect(policy.decide(context(.drag(hold: true), window: nil, popup: true)) == .direct)
    policy.forced = .warp
    #expect(policy.decide(context(.tap)) == .warp)
}

@Test func aDirectOverrideCannotApplyWithoutAWindowToTarget() {
    #expect(DeliveryPolicy().decide(context(.tap, window: nil, override: .direct)) == .warp)
}

// Measured in the Event Sink: on an inactive app, Direct clicks are swallowed (first-click rule) and
// pinches dropped, while right-clicks and scrolls arrive.
@Test func gesturesThatNeedTheAppActiveFirst() {
    #expect(DeliveryPolicy.needsActivation(.tap))
    #expect(DeliveryPolicy.needsActivation(.drag(hold: false)))
    #expect(DeliveryPolicy.needsActivation(.drag(hold: true)))
    #expect(DeliveryPolicy.needsActivation(.magnify))
    #expect(DeliveryPolicy.needsActivation(.rotate))
    #expect(!DeliveryPolicy.needsActivation(.scroll))
    #expect(!DeliveryPolicy.needsActivation(.rightClick))
}
