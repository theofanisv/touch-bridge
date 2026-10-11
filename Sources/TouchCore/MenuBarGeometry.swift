/// Every display has its own menu bar (Displays have separate Spaces); status items such as the clock
/// sit at the same distance from each display's right edge.
public enum MenuBarGeometry {
    /// Vertical centre of a standard 24 pt menu bar. The notch display's bar is 38 pt, so its items sit
    /// lower; a point mapped from there is kept inside a standard bar.
    static let standardItemCentre = 12.0

    public static func sameStatusItem(as point: ScreenPoint, on source: ScreenRect, in target: ScreenRect) -> ScreenPoint {
        ScreenPoint(x: target.x + target.width - (source.x + source.width - point.x),
                    y: target.y + min(point.y - source.y, standardItemCentre))
    }
}
