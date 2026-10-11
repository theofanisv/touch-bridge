import AppKit
import ApplicationServices
import TouchCore

/// Read-only diagnostic (`--ax-probe --menubar`): what decides the display that Notification Center,
/// Launchpad and Space switching use. Logs each display's menu bar, the clock as Accessibility reports it
/// on every display, the active menu-bar display and current Space per display, and the Dock's windows.
/// Sends no events.
enum MenuBarProbe {
    static func run(log: (String) -> Void) {
        for id in SystemDisplays.online() {
            let b = CGDisplayBounds(id)
            log("display \(id) vendor \(CGDisplayVendorNumber(id)) model \(CGDisplayModelNumber(id)) at \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))×\(Int(b.height)) uuid \(SystemDisplays.uuid(id) ?? "?") main \(CGDisplayIsMain(id) != 0)")
        }
        for screen in NSScreen.screens {
            log("screen \(screen.localizedName) frame \(screen.frame) visible \(screen.visibleFrame) menu bar \(screen.frame.maxY - screen.visibleFrame.maxY) pt")
        }
        log("active menu-bar display \(SystemDisplays.activeMenuBarDisplayUUID() ?? "unavailable")")
        for (uuid, space) in SystemDisplays.currentSpaces() { log("current space on \(uuid): \(space)") }
        log("cursor at \(CGEvent(source: nil)?.location ?? .zero)")

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var clockFrame: CGRect?
        for bundle in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            let top = children(element).map { role($0) }
            log("\(bundle) pid \(app.processIdentifier) top-level children: \(top)")
            guard let bar = attribute(element, "AXExtrasMenuBar") else { log("  no AXExtrasMenuBar"); continue }
            log("  AXExtrasMenuBar frame \(frame(bar).map { "\($0)" } ?? "?")")
            for item in children(bar) {
                let id = AXProbe.string(item, "AXIdentifier") ?? "?"
                log("  item \(id) frame \(frame(item).map { "\($0)" } ?? "?")")
                if id == "com.apple.menuextra.clock" { clockFrame = frame(item) }
            }
        }

        if let clock = clockFrame {
            let centre = ScreenPoint(x: clock.midX, y: clock.midY)
            let displays = SystemDisplays.online().map { (id: $0, rect: SystemDisplays.rect($0)) }
            if let source = displays.first(where: { $0.rect.contains(centre) }) {
                for d in displays {
                    let p = MenuBarGeometry.sameStatusItem(as: centre, on: source.rect, in: d.rect)
                    let window = WindowHitTester.topWindow(at: p, in: WindowLocator.onScreenWindows(), excludingPID: -1)
                    log("display \(d.id): clock expected at \(Int(p.x)),\(Int(p.y)) → window \(window.map { "\($0.ownerName) pid \($0.pid) layer \($0.layer)" } ?? "none"); AX \(describe(at: CGPoint(x: p.x, y: p.y), system: system))")
                }
            } else {
                log("clock centre \(centre) is on no display")
            }
        }

        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let element = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            for child in children(element) {
                log("Dock AX \(role(child)) frame \(frame(child).map { "\($0)" } ?? "?")")
            }
        }
        for w in WindowLocator.onScreenWindows() where w.ownerName == "Dock" || w.ownerName == "Notification Center" {
            log("\(w.ownerName) window #\(w.number) layer \(w.layer) at \(Int(w.bounds.x)),\(Int(w.bounds.y)) \(Int(w.bounds.width))×\(Int(w.bounds.height)) alpha \(w.alpha)")
        }
        log("done")
    }

    private static func describe(at p: CGPoint, system: AXUIElement) -> String {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let element = hit else { return "nothing" }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        return "\(owner) \(role(element)) id \(AXProbe.string(element, "AXIdentifier") ?? "-") frame \(frame(element).map { "\($0)" } ?? "?")"
    }

    private static func role(_ e: AXUIElement) -> String {
        (AXProbe.string(e, kAXRoleAttribute) ?? "?") + (AXProbe.string(e, kAXSubroleAttribute).map { "/\($0)" } ?? "")
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let p = position, let s = size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}

/// Displays, plus the window server's per-display Space state (private SkyLight calls looked up at runtime;
/// read-only, and each returns nil when missing).
enum SystemDisplays {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func rect(_ id: CGDirectDisplayID) -> ScreenRect {
        let b = CGDisplayBounds(id)
        return ScreenRect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height)
    }

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyString = @convention(c) (Int32) -> Unmanaged<CFString>?
    private typealias CopyArray = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static var connection: Int32? {
        symbol("_CGSDefaultConnection").map { unsafeBitCast($0, to: Connection.self)() }
    }

    /// The display whose menu bar is active (the one with the focused window), as a display UUID.
    static func activeMenuBarDisplayUUID() -> String? {
        guard let cid = connection, let f = symbol("SLSCopyActiveMenuBarDisplayIdentifier") else { return nil }
        return unsafeBitCast(f, to: CopyString.self)(cid)?.takeRetainedValue() as String?
    }

    /// Display UUID → current Space id, for every display with its own Spaces.
    static func currentSpaces() -> [(String, UInt64)] {
        guard let cid = connection, let f = symbol("SLSCopyManagedDisplaySpaces"),
              let displays = unsafeBitCast(f, to: CopyArray.self)(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let current = d["Current Space"] as? [String: Any],
                  let id = (current["id64"] as? NSNumber) ?? (current["ManagedSpaceID"] as? NSNumber) else { return nil }
            return (uuid, id.uint64Value)
        }
    }
}
