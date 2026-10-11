import AppKit
import CoreGraphics

/// Spike: posts vertical dock swipes in both directions and reports whether Mission Control opened
/// (the Dock shows full-screen windows at layers 18/20 while it is open). Closes it again after each try.
public enum DockSwipeSelfTest {
    public static func run(log: @escaping (String) -> Void) {
        let queue = DispatchQueue(label: "dockswipe-selftest")
        let swipe = DockSwipe(queue: queue)
        let scale = CommandLine.arguments.firstIndex(of: "--scale").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 0.05
        if CommandLine.arguments.contains("--pinch-inverted") {
            // Mac Mouse Fix: before macOS 26, pinch dock swipes need the inverted flag (and the sign flipped).
            for sign in [1.0, -1.0] {
                let d = sign * scale
                log("pinch inverted \(sign > 0 ? "+" : "−")")
                swipe.post(delta: d, kind: .pinch, phase: .began, inverted: true)
                for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.016); swipe.post(delta: d, kind: .pinch, phase: .changed, inverted: true) }
                Thread.sleep(forTimeInterval: 0.016)
                swipe.post(delta: d, kind: .pinch, phase: .ended, inverted: true)
                Thread.sleep(forTimeInterval: 4)
            }
            log("done")
            return
        }
        if CommandLine.arguments.contains("--all-kinds") {
            // Watched by the owner: horizontal, pinch, then a guessed type 4, each positive then negative.
            for raw in [Int64(1), 3, 4] {
                for sign in [1.0, -1.0] {
                    let d = sign * scale
                    log("kind \(raw) \(sign > 0 ? "+" : "−")")
                    swipe.postRaw(delta: d, kind: raw, phase: .began)
                    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.016); swipe.postRaw(delta: d, kind: raw, phase: .changed) }
                    Thread.sleep(forTimeInterval: 0.016)
                    swipe.postRaw(delta: d, kind: raw, phase: .ended)
                    Thread.sleep(forTimeInterval: 3)
                }
            }
            log("done")
            return
        }
        for sign in [1.0, -1.0] {
            let d = sign * scale
            log("vertical dock swipe, \(sign > 0 ? "positive" : "negative") steps of \(d)")
            swipe.post(delta: d, kind: .vertical, phase: .began)
            for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.016); swipe.post(delta: d, kind: .vertical, phase: .changed) }
            Thread.sleep(forTimeInterval: 0.016)
            swipe.post(delta: d, kind: .vertical, phase: .ended)
            Thread.sleep(forTimeInterval: 1.2)
            let open = missionControlOpen()
            log("  → Mission Control open: \(open)")
            if open {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                Thread.sleep(forTimeInterval: 1.2)
                log("  closed again: \(!missionControlOpen())")
            }
        }
        log("done")
    }

    static func missionControlOpen() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "Dock" && [18, 20].contains(w[kCGWindowLayer as String] as? Int ?? 0)
                && !((w[kCGWindowName as String] as? String) ?? "").hasPrefix("Wallpaper")
        }
    }
}
