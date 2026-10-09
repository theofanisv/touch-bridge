import CoreGraphics
import Foundation
import TouchCore

/// A window that receives events straight from TouchBridge (Direct delivery), without the cursor moving.
///
/// CGEventPostToPid alone delivers events with no window attached (AppKit sees windowNumber 0 and
/// drops them). The window server normally fills in two things when it routes an event, and we do the same:
/// - field 51: the window number (AppKit's NSEvent.windowNumber; fields 91/92 are not used for this)
/// - the window-relative location, top-left origin, via the private CGEventSetWindowLocation
/// Found by diffing routed and posted events in the Event Sink (see docs/spec.md, ledger).
struct DirectTarget: Equatable {
    let pid: Int32
    let window: Int
    /// The window's top-left corner in global display points.
    let origin: CGPoint

    private static let windowNumberField = CGEventField(rawValue: 51)!
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }

    /// Whether this macOS still offers the private call Direct delivery depends on.
    static var isAvailable: Bool { setWindowLocation != nil }

    func post(_ event: CGEvent) {
        event.setIntegerValueField(Self.windowNumberField, value: Int64(window))
        let local = DirectAddressing.windowLocation(
            of: ScreenPoint(x: event.location.x, y: event.location.y),
            in: ScreenRect(x: origin.x, y: origin.y, width: 0, height: 0)
        )
        Self.setWindowLocation?(event, CGPoint(x: local.x, y: local.y))
        event.postToPid(pid)
    }
}
