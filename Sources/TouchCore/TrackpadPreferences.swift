/// The Mac's trackpad gesture settings (defaults domain com.apple.AppleMultitouchTrackpad), so the
/// touchscreen can behave like the trackpad. Gestures TouchBridge doesn't implement yet are read too.
public struct TrackpadPreferences: Equatable, Sendable {
    public var threeFingerDrag = false   // macOS default: off
    public var scroll = true
    public var momentum = true
    public var pinch = true
    public var rotate = true
    // Not implemented yet (docs/backlog.md); read so they can follow the settings when they are.
    public var missionControlSwipe = true      // four fingers up / down
    public var spacesSwipe = true              // four fingers left / right
    public var launchpadDesktopPinch = true    // thumb + three/four fingers
    public var notificationCenterSwipe = true  // two fingers from the right edge
    public var lookUpTap = true                // three-finger tap
    public var smartZoom = true                // two-finger double tap

    /// The keys read from the trackpad's defaults domain.
    public static let keys = [
        "TrackpadThreeFingerDrag", "TrackpadScroll", "TrackpadMomentumScroll", "TrackpadPinch", "TrackpadRotate",
        "TrackpadFourFingerVertSwipeGesture", "TrackpadFourFingerHorizSwipeGesture",
        "TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture",
        "TrackpadTwoFingerFromRightEdgeSwipeGesture", "TrackpadThreeFingerTapGesture", "TrackpadTwoFingerDoubleTapGesture",
    ]

    public init() {}

    /// Values are 0 (off) or a non-zero mode/flag (on); missing keys keep the macOS default.
    public init(values: [String: Any]) {
        func on(_ key: String, _ fallback: Bool) -> Bool {
            switch values[key] {
            case let b as Bool: b
            case let i as Int: i != 0
            case let d as Double: d != 0
            default: fallback
            }
        }
        threeFingerDrag = on("TrackpadThreeFingerDrag", false)
        scroll = on("TrackpadScroll", true)
        momentum = on("TrackpadMomentumScroll", true)
        pinch = on("TrackpadPinch", true)
        rotate = on("TrackpadRotate", true)
        missionControlSwipe = on("TrackpadFourFingerVertSwipeGesture", true)
        spacesSwipe = on("TrackpadFourFingerHorizSwipeGesture", true)
        launchpadDesktopPinch = on("TrackpadFourFingerPinchGesture", true) || on("TrackpadFiveFingerPinchGesture", false)
        notificationCenterSwipe = on("TrackpadTwoFingerFromRightEdgeSwipeGesture", true)
        lookUpTap = on("TrackpadThreeFingerTapGesture", true)
        smartZoom = on("TrackpadTwoFingerDoubleTapGesture", true)
    }

    public func apply(to config: inout GestureConfig) {
        config.threeFingerDrag = threeFingerDrag
        config.scrollEnabled = scroll
        config.pinchEnabled = pinch
        config.rotateEnabled = rotate
        config.fourFingerVerticalSwipe = missionControlSwipe
        config.fourFingerHorizontalSwipe = spacesSwipe
        config.fourFingerPinch = launchpadDesktopPinch
        config.notificationCenterSwipe = notificationCenterSwipe
    }

    /// One line for the menu and the log.
    /// The settings TouchBridge follows, in menu order.
    public var settings: [(name: String, on: Bool)] {
        [("3-finger drag", threeFingerDrag), ("scroll", scroll), ("momentum", momentum), ("pinch", pinch), ("rotate", rotate),
         ("Mission Control", missionControlSwipe), ("Spaces", spacesSwipe), ("Launchpad/Desktop", launchpadDesktopPinch),
         ("Notification Center", notificationCenterSwipe)]
    }

    /// One line for the log.
    public var summary: String {
        settings.map { "\($0.name) \($0.on ? "on" : "off")" }.joined(separator: " · ")
    }
}
