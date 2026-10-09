/// How a gesture reaches an app: posted straight to the app (cursor never moves) or by briefly
/// moving the hidden cursor to the finger and posting through the window server.
public enum DeliveryMode: String, Codable, Equatable, Sendable { case direct, warp }

public enum GestureKind: Equatable, Sendable {
    case tap, rightClick, drag(hold: Bool), scroll, magnify, rotate
}

/// What happens to keyboard focus after a touch activated an app (menu switch).
public enum FocusMode: String, Codable, Equatable, Sendable {
    /// The touched app stays active, like a normal click.
    case followTouch
    /// The previously active app is re-activated shortly after the touch.
    case returnToPrevious
}

/// An on-screen window as reported by CGWindowListCopyWindowInfo (bounds in global points).
public struct WindowInfo: Equatable, Sendable {
    public let number: Int
    public let pid: Int32
    public let ownerName: String
    public let layer: Int
    public let bounds: ScreenRect
    public let alpha: Double

    public init(number: Int, pid: Int32, ownerName: String, layer: Int, bounds: ScreenRect, alpha: Double) {
        self.number = number
        self.pid = pid
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    func contains(_ p: ScreenPoint) -> Bool {
        p.x >= bounds.x && p.x < bounds.x + bounds.width && p.y >= bounds.y && p.y < bounds.y + bounds.height
    }
}

public enum WindowHitTester {
    static let popupMenuLayer = 101

    /// `windows` must be front-to-back.
    public static func topWindow(at point: ScreenPoint, in windows: [WindowInfo], excludingPID ownPID: Int32) -> WindowInfo? {
        windows.first { $0.pid != ownPID && $0.alpha > 0 && $0.contains(point) }
    }

    public static func popupMenuVisible(in windows: [WindowInfo]) -> Bool {
        windows.contains { $0.layer == popupMenuLayer }
    }
}

public struct DeliveryContext: Equatable, Sendable {
    public var kind: GestureKind
    public var window: WindowInfo?
    public var point: ScreenPoint
    public var popupMenuVisible: Bool
    public var appIsChromium: Bool
    public var appOverride: DeliveryMode?
    /// Whether this drag moves the window (decided by WindowDragRules from Accessibility).
    public var startsWindowDrag: Bool

    public init(kind: GestureKind, window: WindowInfo?, point: ScreenPoint, popupMenuVisible: Bool, appIsChromium: Bool,
                appOverride: DeliveryMode?, startsWindowDrag: Bool = false) {
        self.kind = kind
        self.window = window
        self.point = point
        self.popupMenuVisible = popupMenuVisible
        self.appIsChromium = appIsChromium
        self.appOverride = appOverride
        self.startsWindowDrag = startsWindowDrag
    }
}

/// Picks Direct or Warp once per gesture (spec: "Delivery policy").
public struct DeliveryPolicy: Equatable, Sendable {
    /// Menu switch for compatibility testing: forces one mode for everything.
    public var forced: DeliveryMode?
    /// Whether pinch and rotate may go Direct (decided by the M1 compatibility matrix).
    public var gesturesDirect = true

    static let systemOwners: Set<String> = [
        "Dock", "SystemUIServer", "Control Center", "ControlCenter",
        "Notification Center", "NotificationCenter", "Spotlight", "Window Server", "WindowServer",
    ]
    static let directLayers: Set<Int> = [0, 3]

    public init() {}

    /// Whether the target app must be active before the gesture is delivered.
    public static func needsActivation(_ kind: GestureKind) -> Bool {
        switch kind {
        case .tap, .drag, .magnify, .rotate: true
        case .scroll, .rightClick: false
        }
    }

    public func decide(_ c: DeliveryContext) -> DeliveryMode {
        if let forced { return forced }
        if c.kind == .drag(hold: true) { return .warp }
        guard let window = c.window else { return .warp }  // Direct needs a window to post to
        if let override = c.appOverride { return override }
        if c.appIsChromium || Self.systemOwners.contains(window.ownerName) || !Self.directLayers.contains(window.layer) || c.popupMenuVisible {
            return .warp
        }
        if c.kind == .drag(hold: false), c.startsWindowDrag { return .warp }
        if (c.kind == .magnify || c.kind == .rotate) && !gesturesDirect { return .warp }
        return .direct
    }
}
