/// After a Space switch on the touch display, macOS gives focus to that display. When focus was on another
/// display, the app that had it gets it back: the first time focus moves away within 1.5 s of the swipe.
public struct FocusKeeper: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case wait, restore(Int32), stop }

    static let windowNs: UInt64 = 1_500_000_000

    public let pid: Int32
    private let startedNs: UInt64

    public init(pid: Int32, startedNs: UInt64) {
        self.pid = pid
        self.startedNs = startedNs
    }

    public func poll(frontmost: Int32?, atNs now: UInt64) -> Action {
        if let frontmost, frontmost != pid { return .restore(pid) }
        return now &- startedNs >= Self.windowNs ? .stop : .wait
    }
}
