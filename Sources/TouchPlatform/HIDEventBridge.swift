import CoreGraphics
import Foundation

/// The low-level HID event a real trackpad attaches to its CGEvents. AppKit's swipe tracking (Safari
/// back/forward) seems to read swipe progress from it, and synthetic scroll events carry none (backlog 5).
/// Private IOKit and SkyLight calls, looked up at runtime; every function is a no-op when they're missing.
public enum HIDEventBridge {
    private typealias CreateScroll = @convention(c) (CFAllocator?, UInt64, Double, Double, Double, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias SetPhase = @convention(c) (CFTypeRef, UInt16) -> Void
    private typealias SetSender = @convention(c) (CFTypeRef, UInt64) -> Void
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias CreateVendor = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UnsafePointer<UInt8>, UInt32, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CopyAttached = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    private static let createScroll = symbol("IOHIDEventCreateScrollEvent", as: CreateScroll.self)
    private static let setPhase = symbol("IOHIDEventSetPhase", as: SetPhase.self)
    private static let setSender = symbol("IOHIDEventSetSenderID", as: SetSender.self)
    private static let attach = symbol("SLEventSetIOHIDEvent", as: Attach.self)
    private static let append = symbol("IOHIDEventAppendEvent", as: Append.self)
    private static let createVendor = symbol("IOHIDEventCreateVendorDefinedEvent", as: CreateVendor.self)
    private static let copyAttached = symbol("CGEventCopyIOHIDEvent", as: CopyAttached.self)

    public static var isAvailable: Bool {
        createScroll != nil && setPhase != nil && attach != nil
    }

    /// The attached HID event, as IOKit describes it (type, phase, sender, fields, children); nil if none.
    public static func describeAttached(_ event: CGEvent) -> String? {
        guard let hid = copyAttached?(event)?.takeRetainedValue() else { return nil }
        return CFCopyDescription(hid) as String
    }

    /// IOHIDEventPhaseBits.
    public enum Phase: UInt16 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 0x80 }

    /// Attaches what the built-in trackpad attaches to a scroll event (seen in the Event Sink, 2026-10-11):
    /// a built-in scroll event (accelerated delta) with a child scroll event carrying the finger's travel
    /// (about a tenth of the pixel delta, flags 0x10010) and, optionally, the multitouch driver's vendor
    /// event (usage page 0xFF00, usage 0x18, 124 bytes). `dx`, `dy` are the CGEvent's pixel deltas.
    @discardableResult
    public static func attachTrackpadScroll(to event: CGEvent, dx: Double, dy: Double, phase: Phase, senderID: UInt64,
                                            vendorData: Bool, gestureUnderway: Bool) -> Bool {
        guard let createScroll, let setPhase, let attach, let append else { return false }
        let ts = mach_absolute_time()
        let travel = (x: -dx * 0.099, y: -dy * 0.099)
        guard let parent = createScroll(nil, ts, -dx * 1.4, -dy * 1.4, 0, 0x10)?.takeRetainedValue(),
              let child = createScroll(nil, ts, travel.x, travel.y, 0, 0x10010)?.takeRetainedValue() else { return false }
        setPhase(parent, phase.rawValue)
        setPhase(child, phase.rawValue)
        setSender?(parent, senderID)
        append(parent, child, 0)
        if vendorData, let createVendor {
            var blob = [UInt8](repeating: 0, count: 124)
            func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                withUnsafeBytes(of: value.littleEndian) { for (i, byte) in $0.enumerated() { blob[offset + i] = byte } }
            }
            func fixed(_ v: Double) -> Int32 { Int32(((v * 10).rounded() / 10) * 65536) }
            put(Int32(22), at: 0)
            put(ts, at: 12)
            put(senderID, at: 28)
            put(Int16(travel.y.rounded()), at: 40)
            put(Int16(travel.x.rounded()), at: 42)
            blob[46] = 0x09
            blob[47] = UInt8(truncatingIfNeeded: phase.rawValue)
            put(fixed(travel.y), at: 48)
            put(fixed(travel.x), at: 52)
            put(Int32(-dy.rounded()), at: 60)
            put(Int32(-dx.rounded()), at: 64)
            if gestureUnderway { put(Int32(1), at: 76) }
            put(UInt32(truncatingIfNeeded: senderID), at: 80)
            put(Int32(1), at: 88)
            let vendor = blob.withUnsafeBufferPointer { createVendor(nil, ts, 0xFF00, 0x18, 0, $0.baseAddress!, 124, 0x1)?.takeRetainedValue() }
            if let vendor { append(parent, vendor, 0) }
        }
        attach(event, parent)
        return true
    }

    /// Attaches a HID scroll event (`x`, `y` in the device's units) with `phase` to `event`.
    @discardableResult
    public static func attachScroll(to event: CGEvent, x: Double, y: Double, phase: Phase, senderID: UInt64? = nil) -> Bool {
        guard let createScroll, let setPhase, let attach,
              let hid = createScroll(nil, mach_absolute_time(), x, y, 0, 0)?.takeRetainedValue() else { return false }
        setPhase(hid, phase.rawValue)
        if let senderID { setSender?(hid, senderID) }
        attach(event, hid)
        return true
    }
}
