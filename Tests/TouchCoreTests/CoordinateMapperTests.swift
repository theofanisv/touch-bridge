import Testing
@testable import TouchCore

// ARZOPA sits to the right of the MacBook screen in global points.
private let arzopa = ScreenRect(x: 1728, y: 0, width: 1920, height: 1080)

@Test func mapsPanelCornersAndCentreOntoTheDisplayBounds() {
    let mapper = CoordinateMapper(bounds: arzopa, rotation: 0)
    #expect(mapper.point(x: 0, y: 0) == ScreenPoint(x: 1728, y: 0))
    #expect(mapper.point(x: 1, y: 1) == ScreenPoint(x: 3648, y: 1080))
    #expect(mapper.point(x: 0.5, y: 0.5) == ScreenPoint(x: 2688, y: 540))
}

@Test func rotation180FlipsBothAxes() {
    let mapper = CoordinateMapper(bounds: arzopa, rotation: 180)
    #expect(mapper.point(x: 0, y: 0) == ScreenPoint(x: 3648, y: 1080))
    #expect(mapper.point(x: 0.25, y: 0.75) == ScreenPoint(x: 1728 + 1440, y: 270))
}

// Convention (verified on hardware in M5): macOS "90°" turns the picture clockwise on the panel,
// so the panel's native top-right corner is the desktop's top-left.
@Test func rotation90MapsNativeTopRightToDesktopTopLeft() {
    let portrait = ScreenRect(x: 1728, y: 0, width: 1080, height: 1920)
    let mapper = CoordinateMapper(bounds: portrait, rotation: 90)
    #expect(mapper.point(x: 1, y: 0) == ScreenPoint(x: 1728, y: 0))
    #expect(mapper.point(x: 0, y: 1) == ScreenPoint(x: 2808, y: 1920))
}

@Test func rotation270IsTheMirrorOf90() {
    let portrait = ScreenRect(x: 1728, y: 0, width: 1080, height: 1920)
    let mapper = CoordinateMapper(bounds: portrait, rotation: 270)
    #expect(mapper.point(x: 0, y: 1) == ScreenPoint(x: 1728, y: 0))
    #expect(mapper.point(x: 1, y: 0) == ScreenPoint(x: 2808, y: 1920))
}

@Test func lastPixelStaysInsideTheDisplay() {
    // CG global bounds are half-open; a touch at the panel edge must still hit this display.
    let mapper = CoordinateMapper(bounds: arzopa, rotation: 0)
    let p = mapper.clampedPoint(x: 1, y: 1)
    #expect(p.x < 3648 && p.y < 1080)
}
