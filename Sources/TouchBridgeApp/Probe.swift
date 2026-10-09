import AppKit
import ApplicationServices
import IOKit.hid
import TouchCore
import TouchPlatform

/// M1 probe: seizes the panel for a fixed time, records every raw report as JSON lines,
/// and writes a summary that answers the multitouch gate. Exits on its own, which releases the panel.
@MainActor
final class Probe {
    private let duration: Double
    private let source = HIDTouchSource()
    private let recorder: ProbeRecorder
    private let started = Date()
    private var signalSources: [DispatchSourceSignal] = []
    private var featureReports: [String] = []

    init(duration: Double) {
        self.duration = duration
        recorder = ProbeRecorder(directory: ProbeRecorder.logDirectory, stamp: ProbeRecorder.stamp())
    }

    func run() -> Never {
        recorder.log("TouchBridge probe, \(Int(duration)) s; raw reports → \(recorder.reportsURL.path)")
        checkPermissions()
        logDisplays()
        installSignalHandlers()

        source.onStatus = { [recorder] in recorder.log($0) }
        source.onReport = { [recorder] timestamp, bytes in recorder.record(timestamp: timestamp, bytes: bytes) }
        source.start()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            readFeatureReports()
            try? await Task.sleep(for: .seconds(2))
            if !source.hasMatchedDevice {
                recorder.log("no HID device for the panel — another driver may own it at USB level (e.g. UPDD). Check: ioreg -r -n ILITEK-TOUCH | grep UsbExclusiveOwner")
            }
        }
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(5))
                recorder.log(summary(final: false))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            finish()
        }
        dispatchMain()
    }

    private func checkPermissions() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt, a C global Swift 6 treats as unsafe shared state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        recorder.log("Accessibility: \(trusted ? "granted" : "NOT granted (a prompt was shown; grant it, then run the probe again)")")
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        recorder.log("Input Monitoring: \(listen == kIOHIDAccessTypeGranted ? "granted" : listen == kIOHIDAccessTypeDenied ? "denied" : "not decided")")
    }

    private func logDisplays() {
        for d in DisplayLocator.onlineDisplays() {
            recorder.log("display \(d.id) \"\(d.name)\" vendor=\(d.vendor) model=\(d.model) serial=\(d.serial) bounds=\(d.bounds) rotation=\(d.rotation)\(d.isMain ? " main" : "")")
        }
    }

    private func readFeatureReports() {
        for (id, length) in [(UInt8(2), 2), (UInt8(6), 257)] {
            if let bytes = source.readFeatureReport(id: id, length: length) {
                let line = "feature RID \(id) (\(bytes.count) bytes): \(ProbeRecorder.hex(bytes))"
                featureReports.append(line)
                recorder.log(line)
            }
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { () -> Void in self.finish() } }
            s.resume()
            signalSources.append(s)
        }
    }

    private func finish() -> Never {
        source.stop()
        let text = summary(final: true)
        recorder.log(text)
        recorder.writeSummary(text)
        exit(0)
    }

    private func summary(final: Bool) -> String {
        let stats = recorder.snapshot()
        let elapsed = Int(Date().timeIntervalSince(started))
        let byID = stats.reportsByID.sorted { $0.key < $1.key }.map { "RID \($0.key)=\($0.value)" }.joined(separator: ", ")
        let interval = stats.medianIntervalMs.map { String(format: "%.2f ms (~%.0f Hz)", $0, 1000 / $0) } ?? "n/a"
        var lines = [
            "\(final ? "FINAL" : "progress") summary after \(elapsed) s",
            "  reports: \(byID.isEmpty ? "none yet — touch the ARZOPA screen" : byID)",
            "  RID 4 max simultaneous contacts: \(stats.maxSimultaneousContacts) → multitouch gate \(stats.multitouchGatePassed ? "PASS" : "not passed yet")",
            "  distinct contact ids: \(stats.distinctContactIDs.sorted())",
            "  median report interval: \(interval)",
            "  median scan-time step: \(stats.medianScanTimeStep.map(String.init) ?? "n/a")",
        ]
        if final { lines += featureReports.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }
}

/// Owns the probe's files and statistics. Report recording happens only on the HID queue.
final class ProbeRecorder: @unchecked Sendable {
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TouchBridge")

    let reportsURL: URL
    private let logURL: URL
    private let summaryURL: URL
    private let reports: FileHandle?
    private let lock = NSLock()
    private var stats = ProbeStats()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(directory: URL, stamp: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reportsURL = directory.appending(path: "probe-\(stamp).jsonl")
        logURL = directory.appending(path: "probe-\(stamp).log")
        summaryURL = directory.appending(path: "probe-\(stamp)-summary.txt")
        FileManager.default.createFile(atPath: reportsURL.path, contents: nil)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        reports = try? FileHandle(forWritingTo: reportsURL)
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func record(timestamp: UInt64, bytes: [UInt8]) {
        let ns = timestamp * UInt64(timebase.numer) / UInt64(timebase.denom)
        let frame = ReportParser.parse(bytes)
        let reportID = bytes.first ?? 0
        lock.withLock { stats.record(timestampNs: ns, reportID: reportID, frame: frame) }

        var line = "{\"t_ns\":\(ns),\"rid\":\(reportID),\"len\":\(bytes.count),\"hex\":\"\(Self.hex(bytes))\""
        if let frame {
            let contacts = frame.contacts.map { String(format: "{\"id\":%d,\"tip\":%@,\"x\":%.5f,\"y\":%.5f}", $0.id, $0.touching ? "true" : "false", $0.x, $0.y) }
            line += ",\"contacts\":[\(contacts.joined(separator: ","))]"
            if let scan = frame.scanTime { line += ",\"scan\":\(scan)" }
        }
        line += "}\n"
        reports?.write(Data(line.utf8))
    }

    func snapshot() -> ProbeStats { lock.withLock { stats } }

    func log(_ message: String) {
        let line = "\(Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    func writeSummary(_ text: String) {
        try? text.write(to: summaryURL, atomically: true, encoding: .utf8)
    }
}
