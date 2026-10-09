/// Direct delivery must address a window the way the window server does when it routes an event:
/// the window number plus the point relative to the window's top-left corner (found on hardware, see spec).
public enum DirectAddressing {
    public static func windowLocation(of point: ScreenPoint, in window: ScreenRect) -> ScreenPoint {
        ScreenPoint(x: point.x - window.x, y: point.y - window.y)
    }
}
