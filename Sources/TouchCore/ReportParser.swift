/// One finger in a frame. Coordinates are normalized to 0...1 across the panel.
public struct Contact: Equatable, Sendable {
    public let id: UInt8
    public let touching: Bool
    public let x: Double
    public let y: Double

    public init(id: UInt8, touching: Bool, x: Double, y: Double) {
        self.id = id
        self.touching = touching
        self.x = x
        self.y = y
    }
}

/// All contacts reported by one HID input report.
public struct TouchFrame: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case digitizer, mouse }

    public let source: Source
    public let contacts: [Contact]
    /// Device scan time (RID 4 only); units are confirmed by the M1 probe.
    public let scanTime: UInt32?
}

/// Decodes ILITEK-TOUCH (USB 0x222A:0x0001) input reports, layout taken from its HID report descriptor.
public enum ReportParser {
    static let logicalMaxX = 16384.0
    static let logicalMaxY = 9600.0

    // RID 4: 10 slots of 5 bytes from byte 1, ScanTime LE32 @51, ContactCount @55, 64 bytes total.
    static let digitizerReportID: UInt8 = 0x04
    static let digitizerReportLength = 64
    static let slotCount = 10
    static let slotSize = 5
    static let scanTimeOffset = 51
    static let contactCountOffset = 55

    // RID 5: buttons @1, X LE16 @2, Y LE16 @4.
    static let mouseReportID: UInt8 = 0x05
    static let mouseReportLength = 6

    public static func parse(_ bytes: [UInt8]) -> TouchFrame? {
        guard let reportID = bytes.first else { return nil }
        switch reportID {
        case digitizerReportID where bytes.count >= digitizerReportLength:
            return parseDigitizer(bytes)
        case mouseReportID where bytes.count >= mouseReportLength:
            return parseMouse(bytes)
        default:
            return nil
        }
    }

    private static func parseDigitizer(_ r: [UInt8]) -> TouchFrame {
        let count = min(Int(r[contactCountOffset]), slotCount)
        let contacts = (0..<count).map { slot -> Contact in
            let base = 1 + slot * slotSize
            return Contact(
                id: r[base] & 0x3F,
                touching: r[base] & 0x40 != 0,
                x: normalize(le16(r, base + 1), logicalMaxX),
                y: normalize(le16(r, base + 3), logicalMaxY)
            )
        }
        let scanTime = (0..<4).reduce(UInt32(0)) { $0 | UInt32(r[scanTimeOffset + $1]) << (8 * UInt32($1)) }
        return TouchFrame(source: .digitizer, contacts: contacts, scanTime: scanTime)
    }

    private static func parseMouse(_ r: [UInt8]) -> TouchFrame {
        let contact = Contact(
            id: 0,
            touching: r[1] & 0x01 != 0,
            x: normalize(le16(r, 2), logicalMaxX),
            y: normalize(le16(r, 4), logicalMaxY)
        )
        return TouchFrame(source: .mouse, contacts: [contact], scanTime: nil)
    }

    private static func le16(_ r: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(r[offset]) | UInt16(r[offset + 1]) << 8
    }

    private static func normalize(_ value: UInt16, _ max: Double) -> Double {
        min(Double(value) / max, 1)
    }
}
