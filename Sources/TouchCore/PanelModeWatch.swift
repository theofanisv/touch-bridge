/// The panel can report either multitouch frames (RID 4) or single-touch "mouse" frames (RID 5).
/// After losing power it may come back in mouse mode until the host reads its feature reports
/// (as Linux's hid-multitouch does). This decides when to ask, and notices when multitouch returns.
public struct PanelModeWatch: Sendable {
    public enum Action: Equatable, Sendable {
        /// Read the panel's feature reports to switch it to multitouch.
        case requestMultitouch
        /// Multitouch frames arrive again after mouse frames.
        case multitouchRestored
    }

    static let retryIntervalNs: UInt64 = 5_000_000_000
    private var lastRequestNs: UInt64?
    private var sawMouse = false

    public init() {}

    public mutating func observe(_ source: TouchFrame.Source, atNs now: UInt64) -> Action? {
        switch source {
        case .mouse:
            sawMouse = true
            if let last = lastRequestNs, now - last < Self.retryIntervalNs { return nil }
            lastRequestNs = now
            return .requestMultitouch
        case .digitizer:
            guard sawMouse else { return nil }
            sawMouse = false
            return .multitouchRestored
        }
    }
}
