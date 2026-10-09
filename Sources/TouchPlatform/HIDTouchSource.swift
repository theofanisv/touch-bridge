import Foundation
import IOKit.hid

/// Finds the ILITEK touch panel, opens it exclusively (seize) and delivers raw input reports.
/// IOHIDManager is used only for matching. For each match we create our own IOHIDDevice,
/// because the manager's device objects are already activated and IOKit requires every
/// "Register" call to happen before activation. All device callbacks run on `queue`.
public final class HIDTouchSource: @unchecked Sendable {
    public static let vendorID = 0x222A
    public static let productID = 0x0001
    static let reportBufferSize = 64

    public let queue = DispatchQueue(label: "com.theofanis.touchbridge.hid", qos: .userInteractive)

    /// (mach absolute timestamp, report bytes including the report ID at index 0)
    public var onReport: ((UInt64, [UInt8]) -> Void)?
    public var onStatus: ((String) -> Void)?

    /// A fresh manager per start: a cancelled IOHIDManager can't be registered or activated again
    /// (IOKit asserts; "Disable → Enable" crashed before this). Only touched by start/stop.
    private var manager: IOHIDManager?
    /// Seized devices; only touched on `queue`.
    private var devices: [IOHIDDevice] = []
    private var matchedAny = false

    public init() {}

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_Digitizer,
            kIOHIDPrimaryUsageKey: kHIDUsage_Dig_TouchScreen,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, matched in
            // May run on the thread calling IOHIDManagerActivate (devices already present) or on the queue (hotplug).
            guard let ctx, let device = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(matched)) else { return }
            let source = Unmanaged<HIDTouchSource>.fromOpaque(ctx).takeUnretainedValue()
            let box = DeviceBox(device: device)
            source.queue.async { source.attach(box.device) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerSetDispatchQueue(manager, queue)
        // IOHIDManager.h: release the manager only after it is cancelled and this handler has run.
        let keepAlive = ManagerBox(manager: manager)
        IOHIDManagerSetCancelHandler(manager) { _ = keepAlive }
        IOHIDManagerActivate(manager)
        onStatus?("matching started (VID 0x222A PID 0x0001, digitizer/touch screen)")
    }

    /// Closes every seized device, which hands the panel back to macOS.
    public func stop() {
        queue.sync {
            for device in devices {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                IOHIDDeviceCancel(device)
            }
            devices.removeAll()
            if let manager { IOHIDManagerCancel(manager) }
            manager = nil
        }
        onStatus?("stopped; panel released")
    }

    /// True once the panel has matched as a HID device (whether or not the seize succeeded).
    public var hasMatchedDevice: Bool { queue.sync { matchedAny } }

    /// Reads a feature report (e.g. RID 2 contact-count max, RID 6 vendor blob). Read-only.
    public func readFeatureReport(id: UInt8, length: Int) -> [UInt8]? {
        queue.sync {
            guard let device = devices.first else { return nil }
            var bytes = [UInt8](repeating: 0, count: length)
            var size = CFIndex(length)
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &bytes, &size)
            guard result == kIOReturnSuccess else {
                onStatus?("feature report \(id) read failed: \(Self.describe(result))")
                return nil
            }
            return Array(bytes.prefix(size))
        }
    }

    private func attach(_ device: IOHIDDevice) {
        matchedAny = true
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            onStatus?("seize failed: \(Self.describe(result))")
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.reportBufferSize, { ctx, result, _, _, _, report, length, timestamp in
            guard result == kIOReturnSuccess, let ctx else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<HIDTouchSource>.fromOpaque(ctx).takeUnretainedValue().onReport?(timestamp, bytes)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { ctx, _, sender in
            guard let ctx, let sender else { return }
            Unmanaged<HIDTouchSource>.fromOpaque(ctx).takeUnretainedValue().detach(Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue())
        }, context)
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceSetCancelHandler(device) { buffer.deallocate() }
        IOHIDDeviceActivate(device)
        devices.append(device)
        onStatus?("panel seized")
    }

    private func detach(_ device: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { CFEqual($0, device) }) else { return }
        IOHIDDeviceCancel(devices.remove(at: index))
        onStatus?("panel removed")
    }

    static func describe(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnNotPermitted: "kIOReturnNotPermitted (grant Accessibility, then relaunch)"
        case kIOReturnExclusiveAccess: "kIOReturnExclusiveAccess (another app holds the panel)"
        default: String(format: "0x%08X", UInt32(bitPattern: result))
        }
    }
}

/// Carries a CF device object across the hop onto the HID queue.
private struct DeviceBox: @unchecked Sendable {
    let device: IOHIDDevice
}

/// Keeps a cancelled manager alive until its cancel handler has run.
private struct ManagerBox: @unchecked Sendable {
    let manager: IOHIDManager
}
