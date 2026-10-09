public enum ContactPhase: Equatable, Sendable { case began, moved, ended }

/// A per-finger lifecycle change. Coordinates are normalized to 0...1 across the panel.
public struct ContactEvent: Equatable, Sendable {
    public let id: UInt8
    public let phase: ContactPhase
    public let x: Double
    public let y: Double

    public init(id: UInt8, phase: ContactPhase, x: Double, y: Double) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
    }
}

/// Turns successive frames into began/moved/ended events per contact id.
/// A contact ends when its tip lifts, when it disappears from a frame, or when no frame
/// arrives for `liftTimeoutNs` (call `expire` from a timer to catch a lost lift report).
public struct ContactTracker: Sendable {
    private var active: [UInt8: (x: Double, y: Double)] = [:]
    private var lastFrameNs: UInt64 = 0
    private let liftTimeoutNs: UInt64

    public init(liftTimeoutNs: UInt64 = 100_000_000) {
        self.liftTimeoutNs = liftTimeoutNs
    }

    public var activeCount: Int { active.count }

    public mutating func update(_ frame: TouchFrame, atNs now: UInt64) -> [ContactEvent] {
        lastFrameNs = now
        let touching = frame.contacts.filter(\.touching)
        let touchingIDs = Set(touching.map(\.id))

        var ended: [ContactEvent] = []
        for contact in frame.contacts where !contact.touching && active[contact.id] != nil {
            ended.append(ContactEvent(id: contact.id, phase: .ended, x: contact.x, y: contact.y))
            active[contact.id] = nil
        }
        for (id, position) in active.sorted(by: { $0.key < $1.key }) where !touchingIDs.contains(id) {
            ended.append(ContactEvent(id: id, phase: .ended, x: position.x, y: position.y))
            active[id] = nil
        }

        var began: [ContactEvent] = []
        var moved: [ContactEvent] = []
        for contact in touching {
            if let previous = active[contact.id] {
                if previous != (contact.x, contact.y) {
                    moved.append(ContactEvent(id: contact.id, phase: .moved, x: contact.x, y: contact.y))
                }
            } else {
                began.append(ContactEvent(id: contact.id, phase: .began, x: contact.x, y: contact.y))
            }
            active[contact.id] = (contact.x, contact.y)
        }
        return ended + began + moved
    }

    public mutating func expire(atNs now: UInt64) -> [ContactEvent] {
        guard !active.isEmpty, now > lastFrameNs, now - lastFrameNs > liftTimeoutNs else { return [] }
        let ended = active.sorted(by: { $0.key < $1.key }).map { ContactEvent(id: $0.key, phase: .ended, x: $0.value.x, y: $0.value.y) }
        active.removeAll()
        return ended
    }
}
