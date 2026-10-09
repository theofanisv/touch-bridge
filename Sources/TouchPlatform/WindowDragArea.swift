import ApplicationServices
import CoreGraphics
import TouchCore

/// Asks the Accessibility API what is under a point and applies WindowDragRules.
/// Only consulted for pans/drags that start near the top of a window, with a short timeout;
/// any failure falls back to the original 28 pt title-bar rule.
enum WindowDragArea {
    /// Toolbars and title bars live in the top of a window; skip Accessibility below this.
    static let searchBand = 120.0
    /// Per Accessibility message, and for the whole lookup (the walk stops when the budget is spent).
    static let timeout: Float = 0.05
    static let budget: TimeInterval = 0.06

    /// Only used from the pipeline queue.
    nonisolated(unsafe) private static let system: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }()

    static func isDragArea(at point: CGPoint, in window: WindowInfo, useAccessibility: Bool = true) -> Bool {
        let offset = point.y - window.bounds.y
        guard offset >= 0, offset < searchBand else { return false }
        let chain = useAccessibility ? chain(at: point, expectedPID: window.pid) : []
        return WindowDragRules.isDragArea(chain: chain, offset: offset)
    }

    /// "Role" or "Role/Subrole" from the element at the point up to its window; empty if
    /// Accessibility doesn't answer in time or the element belongs to another app.
    static func chain(at point: CGPoint, expectedPID: pid_t) -> [String] {
        let deadline = Date().addingTimeInterval(budget)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else { return [] }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == expectedPID else { return [] }
        var result: [String] = []
        var current: AXUIElement? = element
        while let e = current, result.count < 8, Date() < deadline {
            let role = strip(AXProbe.string(e, kAXRoleAttribute) ?? "Unknown")
            let subrole = AXProbe.string(e, kAXSubroleAttribute).map { "/" + strip($0) } ?? ""
            result.append(role + subrole)
            if role == "Window" { break }
            current = AXProbe.parent(e)
        }
        return result
    }

    private static func strip(_ name: String) -> String {
        name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
    }
}
