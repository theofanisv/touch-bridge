/// Aggregates what the M1 probe needs to decide its gates: which report IDs arrive,
/// how many fingers RID 4 reports at once, the report rate and the scan-time step.
public struct ProbeStats: Sendable {
    public private(set) var reportsByID: [UInt8: Int] = [:]
    public private(set) var maxSimultaneousContacts = 0
    public private(set) var distinctContactIDs: Set<UInt8> = []

    private var lastTimestampNs: UInt64?
    private var lastScanTime: UInt32?
    private var intervalsNs: [UInt64] = []
    private var scanTimeSteps: [UInt32] = []
    private static let sampleLimit = 10_000

    public init() {}

    public var multitouchGatePassed: Bool { maxSimultaneousContacts >= 2 }

    public var medianIntervalMs: Double? {
        Self.median(intervalsNs).map { Double($0) / 1_000_000 }
    }

    public var medianScanTimeStep: UInt32? { Self.median(scanTimeSteps) }

    public mutating func record(timestampNs: UInt64, reportID: UInt8, frame: TouchFrame?) {
        reportsByID[reportID, default: 0] += 1
        if let last = lastTimestampNs, timestampNs > last, intervalsNs.count < Self.sampleLimit {
            intervalsNs.append(timestampNs - last)
        }
        lastTimestampNs = timestampNs

        guard let frame, frame.source == .digitizer else { return }
        maxSimultaneousContacts = max(maxSimultaneousContacts, frame.contacts.filter(\.touching).count)
        distinctContactIDs.formUnion(frame.contacts.map(\.id))
        if let scanTime = frame.scanTime {
            if let last = lastScanTime, scanTime > last, scanTimeSteps.count < Self.sampleLimit {
                scanTimeSteps.append(scanTime - last)
            }
            lastScanTime = scanTime
        }
    }

    private static func median<T: BinaryInteger>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
