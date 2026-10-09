import AppKit
import ApplicationServices
import TouchCore
import TouchPlatform

/// The normal mode: a menu-bar agent that owns the touch panel while enabled.
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let pipeline = InputPipeline()
    private let log = FileLog(name: "touchbridge")
    private var statusItem: NSStatusItem!
    private let panelLine = NSMenuItem(title: "Panel: starting…", action: nil, keyEquivalent: "")
    private let displayLine = NSMenuItem(title: "Display: looking for the ARZOPA…", action: nil, keyEquivalent: "")
    private let gestureLine = NSMenuItem(title: "Last gesture: none", action: nil, keyEquivalent: "")
    private let touchesLine = NSMenuItem(title: "Touches: 0 now · 0 max (tracks up to 10)", action: nil, keyEquivalent: "")
    private var enabledItem: NSMenuItem!
    private var dryRunItem: NSMenuItem!
    private var gesturesDirectItem: NSMenuItem!
    private var returnFocusItem: NSMenuItem!
    private var oneFingerScrollItem: NSMenuItem!
    private var modeItems: [NSMenuItem] = []
    private var running = false
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire() else {
            log.write("another TouchBridge is already running; exiting")
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        installSignalHandlers()
        if CommandLine.arguments.contains("--dry-run") {
            dryRunItem.state = .on
            pipeline.update { $0.dryRun = true }
            log.write("started in dry run (log only)")
        }
        pipeline.onTouchCount = { now, most in
            Task { @MainActor [weak self] in self?.touchesLine.title = "Touches: \(now) now · \(most) max (tracks up to 10)" }
        }
        pipeline.onStatus = { [log] message in
            log.write(message)
            Task { @MainActor [weak self] in self?.show(message) }
        }
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            setEnabled(true)
        } else {
            panelLine.title = "Panel: waiting for Accessibility permission"
            log.write("Accessibility not granted; prompted, waiting")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard AXIsProcessTrusted() else { return }
                    self?.relaunch()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if running { pipeline.stop() }
        log.write("quit; panel released")
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchBridge")
        let menu = NSMenu()
        for line in [panelLine, displayLine, gestureLine, touchesLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        enabledItem = item(menu, "Enabled", #selector(toggleEnabled))
        let modeMenu = NSMenu()
        for (title, tag) in [("Automatic", 0), ("Direct only (testing)", 1), ("Warp only (testing)", 2)] {
            let entry = NSMenuItem(title: title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            entry.state = tag == 0 ? .on : .off
            modeItems.append(entry)
            modeMenu.addItem(entry)
        }
        let modeParent = NSMenuItem(title: "Delivery", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)
        gesturesDirectItem = item(menu, "Pinch & Rotate Direct", #selector(toggleGesturesDirect))
        gesturesDirectItem.state = .on
        oneFingerScrollItem = item(menu, "One-Finger Drag Scrolls (hold, then drag to click-and-drag)", #selector(toggleOneFingerScroll))
        oneFingerScrollItem.state = .on
        returnFocusItem = item(menu, "Return Focus to Previous App", #selector(toggleReturnFocus))
        dryRunItem = item(menu, "Dry Run (log only)", #selector(toggleDryRun))
        menu.addItem(.separator())
        _ = item(menu, "Open Event Sink", #selector(openEventSink))
        _ = item(menu, "Open Logs Folder", #selector(openLogs))
        menu.addItem(.separator())
        _ = item(menu, "Quit TouchBridge", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func show(_ message: String) {
        if message.hasPrefix("panel") || message.hasPrefix("seize") || message.hasPrefix("matching") || message.hasPrefix("stopped") {
            panelLine.title = "Panel: \(message)"
        } else if message.hasPrefix("touch display") {
            displayLine.title = "Display: \(message)"
        } else if message.contains(" → ") {
            gestureLine.title = "Last gesture: \(message)"
        }
    }

    // MARK: actions

    @objc private func toggleEnabled() { setEnabled(!running) }

    private func setEnabled(_ on: Bool) {
        if on, !running {
            pipeline.start()
            running = true
        } else if !on, running {
            pipeline.stop()
            running = false
            panelLine.title = "Panel: released (macOS default behaviour)"
        }
        enabledItem.state = running ? .on : .off
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        let forced: DeliveryMode? = [0: nil, 1: .direct, 2: .warp][sender.tag] ?? nil
        modeItems.forEach { $0.state = $0 == sender ? .on : .off }
        pipeline.update { $0.policy.forced = forced }
        log.write("delivery mode: \(forced.map(\.rawValue) ?? "automatic")")
    }

    @objc private func toggleGesturesDirect() {
        let on = gesturesDirectItem.state != .on
        gesturesDirectItem.state = on ? .on : .off
        pipeline.update { $0.policy.gesturesDirect = on }
    }

    @objc private func toggleOneFingerScroll() {
        let on = oneFingerScrollItem.state != .on
        oneFingerScrollItem.state = on ? .on : .off
        pipeline.update { $0.oneFingerDrag = on ? .scroll : .clickAndDrag }
        log.write("one-finger drag: \(on ? "scroll" : "click-and-drag")")
    }

    @objc private func toggleReturnFocus() {
        let on = returnFocusItem.state != .on
        returnFocusItem.state = on ? .on : .off
        pipeline.update { $0.focus = on ? .returnToPrevious : .followTouch }
        log.write("focus: \(on ? "return to previous app" : "follow touch")")
    }

    @objc private func toggleDryRun() {
        let on = dryRunItem.state != .on
        dryRunItem.state = on ? .on : .off
        pipeline.update { $0.dryRun = on }
        log.write("dry run \(on ? "on" : "off")")
    }

    @objc private func openEventSink() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--event-sink"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileLog.directory)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Privacy grants only reach a new process, so start a fresh copy and exit.
    private func relaunch() {
        permissionTimer?.invalidate()
        log.write("Accessibility granted; relaunching")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        SingleInstance.release()
        NSApp.terminate(nil)
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// Only one TouchBridge may own the panel; a lock file enforces it.
enum SingleInstance {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/TouchBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        descriptor = open(dir.appending(path: "instance.lock").path, O_CREAT | O_RDWR, 0o600)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// Appends timestamped lines to ~/Library/Logs/TouchBridge/<name>.log.
final class FileLog: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TouchBridge")
    private let url: URL
    private let lock = NSLock()

    init(name: String) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        url = Self.directory.appending(path: "\(name).log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    }

    func write(_ message: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
        let line = Data("\(stamp) \(message)\n".utf8)
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
    }
}
