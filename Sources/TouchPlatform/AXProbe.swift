import AppKit
import ApplicationServices
import TouchCore

/// Read-only diagnostic: samples a grid of points across the top band of on-screen windows and logs
/// what the Accessibility API reports there (role chain up to the window, plus the toolbar's frame).
/// Used to design the window-drag-area rules from real apps. Sends no events.
public enum AXProbe {
    public static func run(log: (String) -> Void) {
        if CommandLine.arguments.contains("--map") { map(log: log); return }
        if let i = CommandLine.arguments.firstIndex(of: "--owner"), CommandLine.arguments.indices.contains(i + 1) {
            column(owner: CommandLine.arguments[i + 1], log: log); return
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        let windows = WindowLocator.onScreenWindows().filter { $0.layer == 0 && $0.bounds.width > 300 && $0.bounds.height > 200 && $0.ownerName != "TouchBridge" }
        for w in windows.prefix(8) {
            log("window \(w.ownerName) #\(w.number) at \(Int(w.bounds.x)),\(Int(w.bounds.y)) \(Int(w.bounds.width))×\(Int(w.bounds.height))")
            for dy in [4.0, 12, 20, 27, 32, 38, 45, 52, 60, 75, 95] {
                var row: [String] = []
                for fx in [0.12, 0.3, 0.5, 0.7, 0.88] {
                    let x = w.bounds.x + w.bounds.width * fx, y = w.bounds.y + dy
                    row.append(describe(at: CGPoint(x: x, y: y), system: system, expectPID: w.pid))
                }
                log(String(format: "  dy=%2.0f  ", dy) + row.joined(separator: " | "))
            }
        }
        log("done")
    }

    /// Role chains down one column (20 % of the width) of one app's window, to explain a map.
    private static func column(owner: String, log: (String) -> Void) {
        guard let w = WindowLocator.onScreenWindows().first(where: { $0.ownerName == owner && $0.layer == 0 && $0.bounds.width > 300 }) else { log("no window for \(owner)"); return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        log("window \(w.ownerName) #\(w.number) at \(Int(w.bounds.x)),\(Int(w.bounds.y))")
        for dy in stride(from: 2.0, through: 140, by: 6) {
            let p = CGPoint(x: w.bounds.x + w.bounds.width * 0.2, y: w.bounds.y + dy)
            log(String(format: "  %3.0f pt  %@  %@", dy, WindowDragArea.isDragArea(at: p, in: w) ? "D" : "·", describe(at: p, system: system, expectPID: w.pid)))
        }
        log("done")
    }

    /// Runs the real WindowDragArea decision over a grid on each window: D = a pan moves the window.
    private static func map(log: (String) -> Void) {
        let windows = WindowLocator.onScreenWindows()
        let apps = AppDirectory()   // same Chromium rule as the pipeline
        for w in windows.filter({ $0.layer == 0 && $0.bounds.width > 300 && $0.bounds.height > 200 && $0.ownerName != "TouchBridge" }).prefix(8) {
            log("window \(w.ownerName) #\(w.number) at \(Int(w.bounds.x)),\(Int(w.bounds.y)) \(Int(w.bounds.width))×\(Int(w.bounds.height))   (columns = 5%…95% of width)")
            for dy in stride(from: 2.0, through: 110, by: 6) {
                let row = stride(from: 0.05, through: 0.951, by: 0.05).map { fx -> String in
                    let p = CGPoint(x: w.bounds.x + w.bounds.width * fx, y: w.bounds.y + dy)
                    let top = WindowHitTester.topWindow(at: ScreenPoint(x: p.x, y: p.y), in: windows, excludingPID: -1)
                    guard top?.number == w.number else { return " " }   // covered by another window
                    return WindowDragArea.isDragArea(at: p, in: w, useAccessibility: !apps.isChromium(pid: w.pid)) ? "D" : "·"
                }.joined()
                log(String(format: "  %3.0f pt  ", dy) + row)
            }
        }
        log("done")
    }

    private static func describe(at p: CGPoint, system: AXUIElement, expectPID: pid_t) -> String {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let element = hit else { return "—" }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var chain: [String] = []
        var current: AXUIElement? = element
        while let e = current, chain.count < 6 {
            let role = string(e, kAXRoleAttribute) ?? "?"
            let sub = string(e, kAXSubroleAttribute).map { "/\($0.replacingOccurrences(of: "AX", with: ""))" } ?? ""
            chain.append(role.replacingOccurrences(of: "AX", with: "") + sub)
            if role == kAXWindowRole as String { break }
            current = parent(e)
        }
        return (pid == expectPID ? "" : "[pid \(pid)] ") + chain.joined(separator: "<")
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
