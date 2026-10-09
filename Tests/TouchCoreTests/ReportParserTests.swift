import Testing
@testable import TouchCore

/// Builds a 64-byte ILITEK RID 4 report: 10 slots of (id|tip<<6, X LE16, Y LE16), ScanTime LE32 @51, ContactCount @55.
private func digitizerReport(_ slots: [(id: UInt8, tip: Bool, x: UInt16, y: UInt16)], count: UInt8? = nil, scanTime: UInt32 = 0) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 64)
    r[0] = 0x04
    for (i, s) in slots.enumerated() {
        let base = 1 + i * 5
        r[base] = (s.id & 0x3F) | (s.tip ? 0x40 : 0)
        r[base + 1] = UInt8(s.x & 0xFF); r[base + 2] = UInt8(s.x >> 8)
        r[base + 3] = UInt8(s.y & 0xFF); r[base + 4] = UInt8(s.y >> 8)
    }
    for b in 0..<4 { r[51 + b] = UInt8((scanTime >> (8 * UInt32(b))) & 0xFF) }
    r[55] = count ?? UInt8(slots.count)
    return r
}

@Test func parsesSingleContactAsNormalizedPoint() throws {
    let frame = try #require(ReportParser.parse(digitizerReport([(id: 3, tip: true, x: 8192, y: 4800)], scanTime: 1234)))
    #expect(frame.source == .digitizer)
    #expect(frame.scanTime == 1234)
    #expect(frame.contacts == [Contact(id: 3, touching: true, x: 0.5, y: 0.5)])
}

@Test func parsesOnlyTheReportedNumberOfContacts() throws {
    let report = digitizerReport([(id: 0, tip: true, x: 0, y: 0), (id: 1, tip: true, x: 16384, y: 9600), (id: 2, tip: true, x: 100, y: 100)], count: 2)
    let frame = try #require(ReportParser.parse(report))
    #expect(frame.contacts == [Contact(id: 0, touching: true, x: 0, y: 0), Contact(id: 1, touching: true, x: 1, y: 1)])
}

@Test func keepsLiftedContactsSoTheTrackerSeesTheLift() throws {
    let frame = try #require(ReportParser.parse(digitizerReport([(id: 5, tip: false, x: 8192, y: 4800)])))
    #expect(frame.contacts.first?.touching == false)
}

@Test func clampsOutOfRangeCoordinates() throws {
    let frame = try #require(ReportParser.parse(digitizerReport([(id: 0, tip: true, x: 20000, y: 12000)])))
    #expect(frame.contacts.first?.x == 1)
    #expect(frame.contacts.first?.y == 1)
}

@Test func capsContactCountAtTheTenSlots() throws {
    let frame = try #require(ReportParser.parse(digitizerReport([(id: 0, tip: true, x: 1, y: 1)], count: 99)))
    #expect(frame.contacts.count == 10)
}

@Test func parsesMouseFallbackReportAsOneContact() throws {
    // RID 5: buttons @1, X LE16 @2, Y LE16 @4
    let report: [UInt8] = [0x05, 0x01, 0x00, 0x20, 0xC0, 0x12]
    let frame = try #require(ReportParser.parse(report))
    #expect(frame.source == .mouse)
    #expect(frame.contacts == [Contact(id: 0, touching: true, x: 0.5, y: 0.5)])
}

@Test func rejectsUnknownReportIDsAndShortReports() {
    #expect(ReportParser.parse([0x03] + [UInt8](repeating: 0, count: 63)) == nil)
    #expect(ReportParser.parse([0x04, 0x00]) == nil)
    #expect(ReportParser.parse([]) == nil)
}
