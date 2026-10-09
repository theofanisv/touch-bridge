import Testing
@testable import TouchCore

private func frame(_ touching: [UInt8], lifted: [UInt8] = [], scanTime: UInt32? = 0) -> TouchFrame {
    TouchFrame(
        source: .digitizer,
        contacts: touching.map { Contact(id: $0, touching: true, x: 0.5, y: 0.5) } + lifted.map { Contact(id: $0, touching: false, x: 0.5, y: 0.5) },
        scanTime: scanTime
    )
}

@Test func countsReportsPerReportID() {
    var stats = ProbeStats()
    stats.record(timestampNs: 0, reportID: 4, frame: frame([0]))
    stats.record(timestampNs: 1, reportID: 4, frame: frame([0]))
    stats.record(timestampNs: 2, reportID: 5, frame: nil)
    #expect(stats.reportsByID == [4: 2, 5: 1])
}

@Test func tracksMaxSimultaneousTouchingDigitizerContacts() {
    var stats = ProbeStats()
    stats.record(timestampNs: 0, reportID: 4, frame: frame([0, 1, 2], lifted: [3]))
    stats.record(timestampNs: 1, reportID: 4, frame: frame([0]))
    #expect(stats.maxSimultaneousContacts == 3)
    #expect(stats.distinctContactIDs == [0, 1, 2, 3])
}

@Test func multitouchGatePassesOnlyWithTwoOrMoreSimultaneousContacts() {
    var single = ProbeStats()
    single.record(timestampNs: 0, reportID: 4, frame: frame([0]))
    #expect(single.multitouchGatePassed == false)

    var multi = ProbeStats()
    multi.record(timestampNs: 0, reportID: 4, frame: frame([0, 1]))
    #expect(multi.multitouchGatePassed == true)
}

@Test func mouseFramesDoNotCountTowardMultitouch() {
    var stats = ProbeStats()
    let mouse = TouchFrame(source: .mouse, contacts: [Contact(id: 0, touching: true, x: 0, y: 0)], scanTime: nil)
    stats.record(timestampNs: 0, reportID: 5, frame: mouse)
    #expect(stats.maxSimultaneousContacts == 0)
}

@Test func measuresMedianReportIntervalAndScanTimeStep() throws {
    var stats = ProbeStats()
    // 8 ms apart on the host clock; scan time advances by 80 per report.
    for i in 0..<5 {
        stats.record(timestampNs: UInt64(i) * 8_000_000, reportID: 4, frame: frame([0], scanTime: UInt32(i * 80)))
    }
    #expect(try #require(stats.medianIntervalMs) == 8)
    #expect(try #require(stats.medianScanTimeStep) == 80)
}
