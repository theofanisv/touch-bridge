/// Open Sound Control encoding, as TUIO sends it: big-endian numbers, strings null-terminated and padded to a
/// multiple of four bytes, messages grouped in a bundle.
public enum OSC {
    public enum Argument: Sendable { case string(String), int(Int32), float(Float) }

    public static func string(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    public static func int32(_ v: Int32) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian, Array.init)
    }

    public static func float32(_ v: Float) -> [UInt8] {
        withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)
    }

    public static func message(_ address: String, _ arguments: [Argument]) -> [UInt8] {
        var tags = ","
        var payload: [UInt8] = []
        for argument in arguments {
            switch argument {
            case let .string(s): tags += "s"; payload += string(s)
            case let .int(i): tags += "i"; payload += int32(i)
            case let .float(f): tags += "f"; payload += float32(f)
            }
        }
        return string(address) + string(tags) + payload
    }

    /// A bundle to be handled immediately (time tag 1), each message preceded by its size.
    public static func bundle(_ messages: [[UInt8]]) -> [UInt8] {
        var bytes = string("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1]
        for message in messages { bytes += int32(Int32(message.count)) + message }
        return bytes
    }
}

/// TUIO 1.1 "2Dcur" frames: the multitouch-table protocol that creative apps read (TouchDesigner, Processing,
/// openFrameworks, Unity, Max, Kivy), usually over UDP on port 3333.
public enum TUIO {
    public struct Cursor: Equatable, Sendable {
        public let session: Int32
        /// Position on the touch surface, 0…1, origin top-left.
        public let x: Float
        public let y: Float
        /// Velocity in surface widths / heights per second.
        public let vx: Float
        public let vy: Float
        public let acceleration: Float

        public init(session: Int32, x: Float, y: Float, vx: Float, vy: Float, acceleration: Float) {
            self.session = session
            self.x = x
            self.y = y
            self.vx = vx
            self.vy = vy
            self.acceleration = acceleration
        }
    }

    public static let address = "/tuio/2Dcur"

    /// One frame: who sends it, which cursors are alive (an empty list removes them all), one `set` per
    /// cursor, and the frame number.
    public static func frame(_ cursors: [Cursor], sequence: Int32, source: String = "TouchBridge") -> [UInt8] {
        var messages = [OSC.message(address, [.string("source"), .string(source)]),
                        OSC.message(address, [.string("alive")] + cursors.map { .int($0.session) })]
        for c in cursors {
            messages.append(OSC.message(address, [.string("set"), .int(c.session), .float(c.x), .float(c.y),
                                                  .float(c.vx), .float(c.vy), .float(c.acceleration)]))
        }
        messages.append(OSC.message(address, [.string("fseq"), .int(sequence)]))
        return OSC.bundle(messages)
    }
}

/// Turns the panel's contacts into TUIO cursors. The panel reuses contact ids for new touches, but TUIO needs
/// a fresh session id per touch, plus velocity and acceleration.
public struct TUIOSessions: Sendable {
    private struct Session: Sendable {
        let id: Int32
        var last: PanelPoint
        var ns: UInt64
        var speed: Double
    }

    private var sessions: [UInt8: Session] = [:]
    private var next: Int32 = 1

    public init() {}

    public mutating func update(_ contacts: [UInt8: PanelPoint], atNs now: UInt64) -> [TUIO.Cursor] {
        sessions = sessions.filter { contacts[$0.key] != nil }
        var cursors: [TUIO.Cursor] = []
        for (contact, p) in contacts {
            guard var s = sessions[contact] else {
                sessions[contact] = Session(id: next, last: p, ns: now, speed: 0)
                cursors.append(TUIO.Cursor(session: next, x: Float(p.x), y: Float(p.y), vx: 0, vy: 0, acceleration: 0))
                next = next == Int32.max ? 1 : next + 1
                continue
            }
            let dt = Double(now &- s.ns) / 1e9
            let (vx, vy) = dt > 0 ? ((p.x - s.last.x) / dt, (p.y - s.last.y) / dt) : (0, 0)
            let speed = (vx * vx + vy * vy).squareRoot()
            let acceleration = dt > 0 ? (speed - s.speed) / dt : 0
            s.last = p
            s.ns = now
            s.speed = speed
            sessions[contact] = s
            cursors.append(TUIO.Cursor(session: s.id, x: Float(p.x), y: Float(p.y), vx: Float(vx), vy: Float(vy), acceleration: Float(acceleration)))
        }
        return cursors.sorted { $0.session < $1.session }
    }
}

extension TUIO {
    public struct Frame: Equatable, Sendable {
        public let alive: [Int32]
        public let cursors: [Cursor]
        public let sequence: Int32?

        public init(alive: [Int32], cursors: [Cursor], sequence: Int32?) {
            self.alive = alive
            self.cursors = cursors
            self.sequence = sequence
        }
    }

    /// Reads a TUIO 1.1 "2Dcur" bundle, from `frame` or any other sender. Nil for anything else; malformed
    /// input (anyone on this Mac can send to the port) never traps.
    public static func decode(_ bytes: [UInt8]) -> Frame? {
        var reader = OSCReader(bytes[...])
        guard reader.string() == "#bundle", reader.skip(8) else { return nil }
        var alive: [Int32] = []
        var cursors: [Cursor] = []
        var sequence: Int32?
        var sawTUIO = false
        while !reader.atEnd {
            guard let size = reader.int32(), size > 0, let body = reader.take(Int(size)) else { return nil }
            var message = OSCReader(body)
            guard message.string() == address, let tags = message.string(), tags.first == "," else { continue }
            var args: [OSC.Argument] = []
            for tag in tags.dropFirst() {
                switch tag {
                case "s": guard let s = message.string() else { return nil }; args.append(.string(s))
                case "i": guard let i = message.int32() else { return nil }; args.append(.int(i))
                case "f": guard let f = message.float32() else { return nil }; args.append(.float(f))
                default: return nil
                }
            }
            sawTUIO = true
            guard case let .string(command)? = args.first else { continue }
            switch command {
            case "alive":
                alive = args.dropFirst().compactMap { if case let .int(i) = $0 { i } else { nil } }
            case "set":
                guard args.count >= 7, case let .int(s) = args[1], case let .float(x) = args[2], case let .float(y) = args[3],
                      case let .float(vx) = args[4], case let .float(vy) = args[5], case let .float(a) = args[6] else { continue }
                cursors.append(Cursor(session: s, x: x, y: y, vx: vx, vy: vy, acceleration: a))
            case "fseq":
                if args.count >= 2, case let .int(f) = args[1] { sequence = f }
            default:
                break
            }
        }
        return sawTUIO ? Frame(alive: alive, cursors: cursors, sequence: sequence) : nil
    }
}

/// Reads OSC values from a byte slice, failing (nil) instead of reading past the end.
struct OSCReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
    }

    var atEnd: Bool { bytes.isEmpty }

    mutating func string() -> String? {
        guard let end = bytes.firstIndex(of: 0) else { return nil }
        let length = end - bytes.startIndex
        let consumed = (length + 4) & ~3   // the terminator and padding to four bytes
        guard consumed <= bytes.count else { return nil }
        let s = String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
        bytes = bytes.dropFirst(consumed)
        return s
    }

    mutating func int32() -> Int32? {
        guard bytes.count >= 4 else { return nil }
        let i = bytes.startIndex
        let v = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        bytes = bytes.dropFirst(4)
        return Int32(bitPattern: v)
    }

    mutating func float32() -> Float? {
        int32().map { Float(bitPattern: UInt32(bitPattern: $0)) }
    }

    mutating func skip(_ n: Int) -> Bool {
        guard bytes.count >= n else { return false }
        bytes = bytes.dropFirst(n)
        return true
    }

    mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, bytes.count >= n else { return nil }
        let taken = bytes.prefix(n)
        bytes = bytes.dropFirst(n)
        return taken
    }
}
