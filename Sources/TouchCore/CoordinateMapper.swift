/// A point in global display space (CoreGraphics points, top-left origin of the main display).
public struct ScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A display's bounds in global display space. Kept free of CoreGraphics so TouchCore stays pure.
public struct ScreenRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Maps normalized panel coordinates (native orientation) onto the touch display's global bounds.
/// `rotation` is the display rotation in degrees as reported by CGDisplayRotation; macOS "90°"
/// turns the picture clockwise on the panel (to be confirmed on hardware in M5).
public struct CoordinateMapper: Equatable, Sendable {
    public let bounds: ScreenRect
    public let rotation: Int

    public init(bounds: ScreenRect, rotation: Double) {
        self.bounds = bounds
        self.rotation = ((Int(rotation.rounded()) % 360) + 360) % 360
    }

    public func point(x u: Double, y v: Double) -> ScreenPoint {
        let (lx, ly): (Double, Double) = switch rotation {
        case 90: (v, 1 - u)
        case 180: (1 - u, 1 - v)
        case 270: (1 - v, u)
        default: (u, v)
        }
        return ScreenPoint(x: bounds.x + lx * bounds.width, y: bounds.y + ly * bounds.height)
    }

    /// Like `point`, but never lands on the far edge, which CoreGraphics assigns to the neighbouring display.
    public func clampedPoint(x u: Double, y v: Double) -> ScreenPoint {
        let p = point(x: u, y: v)
        return ScreenPoint(
            x: min(max(p.x, bounds.x), bounds.x + bounds.width - 0.5),
            y: min(max(p.y, bounds.y), bounds.y + bounds.height - 0.5)
        )
    }
}
