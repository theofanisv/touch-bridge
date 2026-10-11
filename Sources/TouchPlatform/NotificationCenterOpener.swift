import AppKit
import ApplicationServices
import TouchCore

/// Opens Notification Center the way a click on the menu-bar clock does: macOS has no public call for it,
/// and it is not one of the dock swipes.
///
/// Notification Center opens on the display that has the cursor at that moment, whichever clock opened it
/// (`--system-ui-selftest`, 2026-10-11). Accessibility only reports the clock of the active menu bar.
enum NotificationCenterOpener {
    struct Clock {
        let element: AXUIElement
        let frame: CGRect
        /// ControlCenter's process, which owns the clock's status-item window on every display.
        let pid: pid_t
    }

    static func clock() -> Clock? {
        guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            return nil
        }
        let app = AXUIElementCreateApplication(controlCenter.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = element(app, "AXExtrasMenuBar"), let items = children(bar),
              let clock = items.first(where: { string($0, "AXIdentifier") == "com.apple.menuextra.clock" }),
              let frame = MenuBarProbe.frame(clock) else { return nil }
        return Clock(element: clock, frame: frame, pid: controlCenter.processIdentifier)
    }

    /// The Accessibility "press" (no cursor movement).
    static func press(_ clock: Clock) -> Bool {
        AXUIElementPerformAction(clock.element, kAXPressAction as CFString) == .success
    }

    /// Where the panel is open: Notification Center's full-display windows (layer 23) on screen.
    static func openPanels() -> [ScreenRect] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier else {
            return []
        }
        return WindowLocator.onScreenWindows().filter { $0.pid == pid && $0.layer == 23 }.map(\.bounds)
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
