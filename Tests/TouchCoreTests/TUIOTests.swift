import Foundation
import Testing
@testable import TouchCore

/// A minimal OSC reader, as a TUIO client would parse the bytes.
private enum Arg: Equatable { case s(String), i(Int32), f(Float) }
private struct Message: Equatable { let address: String; let args: [Arg] }

private func readString(_ b: [UInt8], _ i: inout Int) -> String {
    let end = b[i...].firstIndex(of: 0)!
    let s = String(decoding: b[i..<end], as: UTF8.self)
    i = (end + 4) & ~3
    return s
}
private func readInt(_ b: [UInt8], _ i: inout Int) -> Int32 {
    defer { i += 4 }
    return Int32(bitPattern: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
}
private func readBundle(_ b: [UInt8]) -> [Message] {
    var i = 0
    #expect(readString(b, &i) == "#bundle")
    #expect(Array(b[i..<i + 8]) == [0, 0, 0, 0, 0, 0, 0, 1], "time tag: immediately")
    i += 8
    var messages: [Message] = []
    while i < b.count {
        let size = Int(readInt(b, &i))
        let end = i + size
        let address = readString(b, &i)
        let tags = readString(b, &i)
        var args: [Arg] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "s": args.append(.s(readString(b, &i)))
            case "i": args.append(.i(readInt(b, &i)))
            case "f": args.append(.f(Float(bitPattern: UInt32(bitPattern: readInt(b, &i)))))
            default: Issue.record("unexpected tag \(tag)")
            }
        }
        #expect(i == end, "message size matches its contents")
        messages.append(Message(address: address, args: args))
    }
    return messages
}

@Test func oscStringsAreNullTerminatedAndPaddedToFourBytes() {
    #expect(OSC.string("alive") == Array("alive".utf8) + [0, 0, 0])
    #expect(OSC.string("set") == Array("set".utf8) + [0])
    #expect(OSC.string("fseq") == Array("fseq".utf8) + [0, 0, 0, 0])
    #expect(OSC.int32(258) == [0, 0, 1, 2])
    #expect(OSC.float32(1) == [0x3F, 0x80, 0, 0])
}

@Test func aFrameCarriesSourceAliveSetsAndSequence() {
    let cursors = [TUIO.Cursor(session: 4, x: 0.25, y: 0.5, vx: 0.1, vy: -0.2, acceleration: 0),
                   TUIO.Cursor(session: 9, x: 0.75, y: 0.125, vx: 0, vy: 0, acceleration: 0)]
    let messages = readBundle(TUIO.frame(cursors, sequence: 7))
    #expect(messages.allSatisfy { $0.address == "/tuio/2Dcur" })
    #expect(messages.map { $0.args.first } == [.s("source"), .s("alive"), .s("set"), .s("set"), .s("fseq")])
    #expect(messages[0].args == [.s("source"), .s("TouchBridge")])
    #expect(messages[1].args == [.s("alive"), .i(4), .i(9)])
    #expect(messages[2].args == [.s("set"), .i(4), .f(0.25), .f(0.5), .f(0.1), .f(-0.2), .f(0)])
    #expect(messages[4].args == [.s("fseq"), .i(7)])
}

@Test func anEmptyFrameTellsClientsEveryCursorIsGone() {
    let messages = readBundle(TUIO.frame([], sequence: 8))
    #expect(messages.map { $0.args } == [[.s("source"), .s("TouchBridge")], [.s("alive")], [.s("fseq"), .i(8)]])
}

private let ms: UInt64 = 1_000_000

@Test func eachTouchGetsItsOwnSessionEvenWhenThePanelReusesTheId() {
    var sessions = TUIOSessions()
    #expect(sessions.update([0: PanelPoint(x: 0.1, y: 0.1)], atNs: 0).map(\.session) == [1])
    #expect(sessions.update([0: PanelPoint(x: 0.1, y: 0.1), 1: PanelPoint(x: 0.5, y: 0.5)], atNs: 10 * ms).map(\.session) == [1, 2])
    #expect(sessions.update([1: PanelPoint(x: 0.5, y: 0.5)], atNs: 20 * ms).map(\.session) == [2], "the first touch lifted")
    #expect(sessions.update([0: PanelPoint(x: 0.3, y: 0.3), 1: PanelPoint(x: 0.5, y: 0.5)], atNs: 30 * ms).map(\.session) == [2, 3],
            "the panel reused id 0 for a new touch")
}

@Test func cursorsCarryTheirVelocity() {
    var sessions = TUIOSessions()
    _ = sessions.update([0: PanelPoint(x: 0.1, y: 0.2)], atNs: 0)
    let moved = sessions.update([0: PanelPoint(x: 0.2, y: 0.2)], atNs: 100 * ms)
    #expect(abs(moved[0].vx - 1.0) < 1e-4, "0.1 of the surface in 0.1 s")
    #expect(moved[0].vy == 0)
    #expect(moved[0].x == 0.2)
}

// The Event Sink reads TUIO to paint every finger (owner: "a valid test environment" for multitouch).
@Test func aFrameDecodesBackToItsCursors() {
    let cursors = [TUIO.Cursor(session: 4, x: 0.25, y: 0.5, vx: 0.1, vy: -0.2, acceleration: 0),
                   TUIO.Cursor(session: 9, x: 0.75, y: 0.125, vx: 0, vy: 0, acceleration: 3)]
    let frame = TUIO.decode(TUIO.frame(cursors, sequence: 7))
    #expect(frame == TUIO.Frame(alive: [4, 9], cursors: cursors, sequence: 7))
}

@Test func anEmptyFrameDecodesToNoCursors() {
    #expect(TUIO.decode(TUIO.frame([], sequence: 3)) == TUIO.Frame(alive: [], cursors: [], sequence: 3))
}

@Test func junkNeverCrashesTheDecoder() {
    let good = TUIO.frame([TUIO.Cursor(session: 1, x: 0.5, y: 0.5, vx: 0, vy: 0, acceleration: 0)], sequence: 1)
    #expect(TUIO.decode([]) == nil)
    #expect(TUIO.decode(Array("hello".utf8)) == nil)
    for cut in stride(from: 1, to: good.count, by: 3) { _ = TUIO.decode(Array(good.prefix(cut))) }   // truncated
    var corrupt = good
    corrupt[17] = 0x7F   // a huge message size
    _ = TUIO.decode(corrupt)
    #expect(TUIO.decode(good) != nil, "the intact frame still decodes")
}
