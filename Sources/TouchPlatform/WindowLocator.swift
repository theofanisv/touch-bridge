import AppKit
import CoreGraphics
import TouchCore

/// Reads the on-screen window list (front-to-back). Bounds, pid and layer need no Screen Recording permission.
public enum WindowLocator {
    public static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowInfo(
                number: number,
                pid: pid,
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                bounds: ScreenRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
    }
}

/// Per-process facts, cached by bundle path (scanning Contents/Frameworks once per app).
public final class AppDirectory: @unchecked Sendable {
    private var chromium: [String: Bool] = [:]
    private let lock = NSLock()

    public init() {}

    public func bundleID(pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func isChromium(pid: Int32) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return lock.withLock {
            if let known = chromium[url.path] { return known }
            let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "Contents/Frameworks").path)) ?? []
            let result = frameworks.contains(where: AppTraits.isChromiumFramework(named:))
            chromium[url.path] = result
            return result
        }
    }
}
