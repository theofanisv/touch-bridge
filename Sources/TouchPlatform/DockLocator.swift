import AppKit
import ApplicationServices
import TouchCore

/// Where the Dock and Launchpad are. Launchpad opens on the display that has the Dock, and the Dock moves
/// to a display when the cursor pushes against that display's bottom edge (`--system-ui-selftest`, lp-4).
enum DockLocator {
    private static var dockPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    /// Only a Dock at the bottom moves between displays this way.
    static var isAtBottom: Bool {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return value == nil || value == "bottom"
    }

    /// A point just inside the bottom edge of the Dock's display: the Dock's tile list sits on that edge,
    /// or just below it while auto-hidden. Nil when Accessibility can't tell.
    static func anchor() -> ScreenPoint? {
        guard let pid = dockPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let list = (value as? [AXUIElement])?.first(where: { AXProbe.string($0, kAXRoleAttribute) == "AXList" }),
              let frame = MenuBarProbe.frame(list) else { return nil }
        return ScreenPoint(x: frame.midX, y: frame.minY - 1)
    }

    /// Whether the Dock is on `display`; nil when unknown.
    static func isDock(on display: ScreenRect) -> Bool? {
        anchor().map(display.contains)
    }

    /// Launchpad's full-screen windows: the Dock's, above its own level (20) and below pop-up menus.
    /// Show Desktop and Mission Control use levels 18 and 20.
    static func launchpadWindows() -> [ScreenRect] {
        guard let pid = dockPID else { return [] }
        return WindowLocator.onScreenWindows().filter { $0.pid == pid && $0.layer > 20 && $0.layer < 100 }.map(\.bounds)
    }
}
