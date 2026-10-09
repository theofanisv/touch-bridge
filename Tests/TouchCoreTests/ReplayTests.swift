import Foundation
import Testing
@testable import TouchCore

/// Replays real panel recordings from the M1 probe through the parser and tracker.
struct Recording {
    let frames: [(ns: UInt64, bytes: [UInt8])]

    init(named name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        frames = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let hex = object["hex"] as! String
            let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            return ((object["t_ns"] as! NSNumber).uint64Value, bytes)
        }
    }
}

@Test func everyRecordedFrameParses() throws {
    let recording = try Recording(named: "probe-session-1")
    #expect(recording.frames.count == 3941)
    #expect(recording.frames.allSatisfy { ReportParser.parse($0.bytes) != nil })
}

@Test func trackerKeepsAConsistentLifecycleOnRealData() throws {
    let recording = try Recording(named: "probe-session-1")
    var tracker = ContactTracker()
    var active = Set<UInt8>()
    var begins = 0, ends = 0

    func apply(_ events: [ContactEvent]) {
        for e in events {
            switch e.phase {
            case .began:
                #expect(!active.contains(e.id), "id \(e.id) began twice")
                active.insert(e.id); begins += 1
            case .moved:
                #expect(active.contains(e.id), "id \(e.id) moved before beginning")
            case .ended:
                #expect(active.contains(e.id), "id \(e.id) ended without beginning")
                active.remove(e.id); ends += 1
            }
        }
    }

    for frame in recording.frames {
        apply(tracker.expire(atNs: frame.ns))
        apply(tracker.update(ReportParser.parse(frame.bytes)!, atNs: frame.ns))
        #expect(tracker.activeCount <= 10)
    }
    apply(tracker.expire(atNs: recording.frames.last!.ns + 1_000_000_000))

    #expect(active.isEmpty)
    #expect(begins == ends)
    #expect(begins > 40) // the session had 40+ separate touches
}

@Test func recognizerBalancesEveryGestureOnRealData() throws {
    let recording = try Recording(named: "probe-session-1")
    var tracker = ContactTracker()
    var recognizer = GestureRecognizer()
    var actions: [GestureAction] = []
    for frame in recording.frames {
        actions += recognizer.handle(tracker.expire(atNs: frame.ns), atNs: frame.ns)
        actions += recognizer.handle(tracker.update(ReportParser.parse(frame.bytes)!, atNs: frame.ns), atNs: frame.ns)
    }
    let end = recording.frames.last!.ns + 1_000_000_000
    actions += recognizer.handle(tracker.expire(atNs: end), atNs: end)

    var open: String?
    var histogram: [String: Int] = [:]
    for action in actions {
        let (name, opens, closes): (String, Bool, Bool) = switch action {
        case .tap: ("tap", false, false)
        case .rightClick: ("rightClick", false, false)
        case .dragBegan: ("drag", true, false)
        case .dragMoved: ("drag", false, false)
        case .dragEnded: ("drag", false, true)
        case let .scroll(_, _, phase): ("scroll", phase == .began, false)
        case .scrollEnded: ("scroll", false, true)
        case let .magnify(_, phase): ("magnify", phase == .began, phase == .ended)
        case let .rotate(_, phase): ("rotate", phase == .began, phase == .ended)
        }
        if opens {
            #expect(open == nil, "\(name) began while \(open ?? "") was open")
            open = name
            histogram[name, default: 0] += 1
        } else if closes {
            #expect(open == name, "\(name) ended while \(open ?? "nothing") was open")
            open = nil
        } else if name == "tap" || name == "rightClick" {
            #expect(open == nil)
            histogram[name, default: 0] += 1
        } else {
            #expect(open == name, "\(name) update outside its gesture")
        }
    }
    #expect(open == nil)
    print("recognized in probe-session-1:", histogram.sorted { $0.key < $1.key })
}
