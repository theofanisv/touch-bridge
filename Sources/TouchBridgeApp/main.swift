import AppKit
import TouchPlatform

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--probe") {
    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 90 : 90
    Probe(duration: seconds).run()
}

if arguments.contains("--restart-selftest") {
    // Reproduces "Disable → Enable": start, stop, start the HID source again in one process.
    let log = FileLog(name: "selftest")
    let source = HIDTouchSource()
    source.onStatus = { log.write("hid: \($0)") }
    source.start(); Thread.sleep(forTimeInterval: 0.5)
    source.stop(); log.write("stopped; starting again")
    source.start(); Thread.sleep(forTimeInterval: 0.5)
    source.stop(); log.write("restart survived")
    exit(0)
}

if arguments.contains("--ax-probe") {
    let log = FileLog(name: "axprobe")
    AXProbe.run { log.write($0) }
    exit(0)
}

if arguments.contains("--direct-selftest") {
    let log = FileLog(name: "selftest")
    DirectSelfTest.run { log.write($0) }
    exit(0)
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate = arguments.contains("--event-sink") ? EventSink() : MenuBarApp()
app.delegate = delegate
app.run()
