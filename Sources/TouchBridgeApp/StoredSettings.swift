import Foundation
import TouchCore
import TouchPlatform

/// Menu settings that survive restarts (UserDefaults of com.theofanis.touchbridge). "Enabled" and
/// "Dry Run" are deliberately per-session.
struct StoredSettings: Sendable {
    var delivery: DeliveryMode?          // nil = automatic
    var gesturesDirect = true
    var oneFingerScroll = true
    var returnFocus = false
    var threeFingerDrag: Bool
    var threeFingerAnchor: ThreeFingerAnchor = .centroid

    private static var defaults: UserDefaults { .standard }

    static func load() -> StoredSettings {
        let d = defaults
        var s = StoredSettings(threeFingerDrag: d.object(forKey: "threeFingerDrag") as? Bool ?? trackpadThreeFingerDrag())
        s.delivery = d.string(forKey: "delivery").flatMap(DeliveryMode.init(rawValue:))
        s.gesturesDirect = d.object(forKey: "gesturesDirect") as? Bool ?? true
        s.oneFingerScroll = d.object(forKey: "oneFingerScroll") as? Bool ?? true
        s.returnFocus = d.object(forKey: "returnFocus") as? Bool ?? false
        s.threeFingerAnchor = d.string(forKey: "threeFingerAnchor").flatMap(ThreeFingerAnchor.init(rawValue:)) ?? .centroid
        return s
    }

    func save() {
        let d = Self.defaults
        d.set(delivery?.rawValue, forKey: "delivery")
        d.set(gesturesDirect, forKey: "gesturesDirect")
        d.set(oneFingerScroll, forKey: "oneFingerScroll")
        d.set(returnFocus, forKey: "returnFocus")
        d.set(threeFingerDrag, forKey: "threeFingerDrag")
        d.set(threeFingerAnchor.rawValue, forKey: "threeFingerAnchor")
    }

    func apply(to p: inout PipelineSettings) {
        p.policy.forced = delivery
        p.policy.gesturesDirect = gesturesDirect
        p.oneFingerDrag = oneFingerScroll ? .scroll : .clickAndDrag
        p.focus = returnFocus ? .returnToPrevious : .followTouch
        p.threeFingerDrag = threeFingerDrag
        p.threeFingerAnchor = threeFingerAnchor
    }

    /// The trackpad's "Three-finger drag" setting (System Settings → Accessibility → Pointer Control),
    /// used until the menu setting has been changed once. On if the key is missing.
    static func trackpadThreeFingerDrag() -> Bool {
        let value = CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, "com.apple.AppleMultitouchTrackpad" as CFString)
        return (value as? NSNumber)?.boolValue ?? true
    }
}
