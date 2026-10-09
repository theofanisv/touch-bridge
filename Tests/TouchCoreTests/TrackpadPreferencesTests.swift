import Testing
@testable import TouchCore

// The owner's values from `defaults read com.apple.AppleMultitouchTrackpad` (2026-10-09).
private func ownersTrackpad() -> [String: Any] { [
    "TrackpadThreeFingerDrag": 1, "TrackpadScroll": 1, "TrackpadMomentumScroll": 1, "TrackpadPinch": 1, "TrackpadRotate": 1,
    "TrackpadFourFingerVertSwipeGesture": 2, "TrackpadFourFingerHorizSwipeGesture": 2,
    "TrackpadFourFingerPinchGesture": 2, "TrackpadFiveFingerPinchGesture": 2,
    "TrackpadTwoFingerFromRightEdgeSwipeGesture": 3, "TrackpadThreeFingerTapGesture": 2, "TrackpadTwoFingerDoubleTapGesture": 1,
] }

@Test func readsTheOwnersTrackpadSettings() {
    let prefs = TrackpadPreferences(values: ownersTrackpad())
    #expect(prefs.threeFingerDrag && prefs.scroll && prefs.momentum && prefs.pinch && prefs.rotate)
    #expect(prefs.missionControlSwipe && prefs.spacesSwipe && prefs.launchpadDesktopPinch && prefs.notificationCenterSwipe)
    #expect(prefs.lookUpTap && prefs.smartZoom)
}

@Test func zeroMeansOff() {
    let prefs = TrackpadPreferences(values: ["TrackpadPinch": 0, "TrackpadThreeFingerDrag": false, "TrackpadTwoFingerFromRightEdgeSwipeGesture": 0])
    #expect(!prefs.pinch)
    #expect(!prefs.threeFingerDrag)
    #expect(!prefs.notificationCenterSwipe)
}

@Test func missingKeysUseMacOSDefaults() {
    let prefs = TrackpadPreferences(values: [:])
    #expect(!prefs.threeFingerDrag, "three-finger drag is off by default on macOS")
    #expect(prefs.scroll && prefs.momentum && prefs.pinch && prefs.rotate)
}

@Test func appliesToTheGestureConfiguration() {
    var config = GestureConfig()
    TrackpadPreferences(values: ["TrackpadThreeFingerDrag": 0, "TrackpadPinch": 0, "TrackpadRotate": 1, "TrackpadScroll": 0]).apply(to: &config)
    #expect(!config.threeFingerDrag)
    #expect(!config.pinchEnabled)
    #expect(config.rotateEnabled)
    #expect(!config.scrollEnabled)
}
