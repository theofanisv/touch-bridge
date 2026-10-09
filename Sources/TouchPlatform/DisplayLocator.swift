import AppKit
import CoreGraphics

/// A connected display as seen by CoreGraphics. Bounds are global points (top-left origin of the main display).
public struct DisplayInfo: Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let bounds: CGRect
    public let rotation: Double
    public let isMain: Bool
}

public enum DisplayLocator {
    @MainActor
    public static func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let names = screenNames()
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                id: id,
                name: names[id] ?? "display \(id)",
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                bounds: CGDisplayBounds(id),
                rotation: CGDisplayRotation(id),
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    @MainActor
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }
}
