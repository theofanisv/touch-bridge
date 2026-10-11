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
    private var keepFocusItem: NSMenuItem!
    private var swipePagesItem: NSMenuItem!
    private var oneFingerScrollItem: NSMenuItem!
    private var threeFingerItem: NSMenuItem!
    private var anchorItems: [NSMenuItem] = []
    private var launchpadItems: [NSMenuItem] = []
    private var touchModeItems: [NSMenuItem] = []
    private var stored = StoredSettings.load()
    private var trackpad = TrackpadPreferencesReader.read()
    private var followTrackpadItem: NSMenuItem!
    /// The followed trackpad settings, one indented line each under "Follow Trackpad Settings".
    private var trackpadLines: [NSMenuItem] = []
    private var trackpadTimer: Timer?
    private var loginItem: NSMenuItem!
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
        // Hooks first: anything queued below may already report status.
        pipeline.onTouchCount = { now, most in
            Task { @MainActor [weak self] in self?.touchesLine.title = "Touches: \(now) now · \(most) max (tracks up to 10)" }
        }
        pipeline.onStatus = { [log] message in
            log.write(message)
            Task { @MainActor [weak self] in self?.show(message) }
        }
        log.write("started \(Bundle.main.bundlePath)\(LoginItem.isLaunchdInstance ? " as login item" : "")")
        let initial = stored
        let initialTrackpad = trackpad
        pipeline.update { initial.apply(to: &$0, trackpad: initialTrackpad) }
        log.write("trackpad settings: \(trackpad.summary)\(stored.followTrackpad ? " (followed)" : " (not followed)")")
        watchTrackpadSettings()
        log.write("settings: delivery \(initial.delivery?.rawValue ?? "automatic"), one-finger drag \(initial.oneFingerScroll ? "scrolls" : "clicks-and-drags"), three-finger drag \(initial.threeFingerDrag ? "on (\(initial.threeFingerAnchor.rawValue))" : "off"), pinch & rotate direct \(initial.gesturesDirect), return focus \(initial.returnFocus), launchpad \(initial.launchpadDock.rawValue), keep focus on space switch \(initial.keepFocusOnSpaceSwitch), swipe between pages \(initial.swipeBetweenPages)")
        if CommandLine.arguments.contains("--dry-run") {
            dryRunItem.state = .on
            pipeline.update { $0.dryRun = true }
            log.write("started in dry run (log only)")
        }
        if LoginItem.removeLegacyRegistration() { log.write("removed the old SMAppService login item") }
        refreshLoginItem()
        if CommandLine.arguments.contains("--enable-login-item"), !LoginItem.isLaunchdInstance {
            if enableLoginItem() { return }
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
        menu.autoenablesItems = false   // items greyed out while the trackpad settings decide
        for line in [panelLine, displayLine, gestureLine, touchesLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        enabledItem = item(menu, "Enabled", #selector(toggleEnabled))
        // Per session: every start is back in Gestures, so the panel can't stay stuck in a special mode.
        let touchModeMenu = NSMenu()
        for (title, mode) in [("Gestures", InputMode.gestures),
                              ("Drawing: One Finger Draws, Nothing Else", .drawing),
                              ("Multitouch Apps: All Fingers as TUIO (port 3333)", .multitouch)] {
            let entry = NSMenuItem(title: title, action: #selector(chooseTouchMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = mode == .gestures ? .on : .off
            touchModeItems.append(entry)
            touchModeMenu.addItem(entry)
        }
        let touchModeParent = NSMenuItem(title: "Touch Mode", action: nil, keyEquivalent: "")
        touchModeParent.submenu = touchModeMenu
        menu.addItem(touchModeParent)
        let modeMenu = NSMenu()
        for (title, tag) in [("Automatic", 0), ("Direct only (testing)", 1), ("Warp only (testing)", 2)] {
            let entry = NSMenuItem(title: title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            entry.state = [0: nil, 1: .direct, 2: .warp][tag] == stored.delivery ? .on : .off
            modeItems.append(entry)
            modeMenu.addItem(entry)
        }
        let modeParent = NSMenuItem(title: "Delivery", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)
        gesturesDirectItem = item(menu, "Pinch & Rotate Direct", #selector(toggleGesturesDirect))
        gesturesDirectItem.state = stored.gesturesDirect ? .on : .off
        oneFingerScrollItem = item(menu, "One-Finger Drag Scrolls (hold, then drag to click-and-drag)", #selector(toggleOneFingerScroll))
        oneFingerScrollItem.state = stored.oneFingerScroll ? .on : .off
        swipePagesItem = item(menu, "Swipe Between Pages (Two Fingers)", #selector(toggleSwipePages))
        swipePagesItem.state = stored.swipeBetweenPages ? .on : .off
        followTrackpadItem = item(menu, "Follow Trackpad Settings", #selector(toggleFollowTrackpad))
        for _ in trackpad.settings {
            let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
            trackpadLines.append(line)
            menu.addItem(line)
        }
        threeFingerItem = item(menu, "Three-Finger Drag", #selector(toggleThreeFinger))
        let anchorMenu = NSMenu()
        for (title, anchor) in [("Centre of the Fingers", ThreeFingerAnchor.centroid), ("First Finger to Touch", .firstFinger)] {
            let entry = NSMenuItem(title: title, action: #selector(chooseAnchor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = anchor.rawValue
            entry.state = anchor == stored.threeFingerAnchor ? .on : .off
            anchorItems.append(entry)
            anchorMenu.addItem(entry)
        }
        let anchorParent = NSMenuItem(title: "Three-Finger Drag Point", action: nil, keyEquivalent: "")
        anchorParent.submenu = anchorMenu
        menu.addItem(anchorParent)
        // Launchpad opens on the display that has the Dock.
        let launchpadMenu = NSMenu()
        for (title, mode) in [("Bring the Dock Over, Then Back", LaunchpadDockMode.bringDockAndReturn),
                              ("Bring the Dock Over (it stays)", .bringDock),
                              ("Leave the Dock Where It Is", .leave)] {
            let entry = NSMenuItem(title: title, action: #selector(chooseLaunchpadDock(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = mode == stored.launchpadDock ? .on : .off
            launchpadItems.append(entry)
            launchpadMenu.addItem(entry)
        }
        let launchpadParent = NSMenuItem(title: "Launchpad on the Touch Display", action: nil, keyEquivalent: "")
        launchpadParent.submenu = launchpadMenu
        menu.addItem(launchpadParent)
        returnFocusItem = item(menu, "Return Focus to Previous App", #selector(toggleReturnFocus))
        returnFocusItem.state = stored.returnFocus ? .on : .off
        keepFocusItem = item(menu, "Keep Focus When Switching Spaces", #selector(toggleKeepFocus))
        keepFocusItem.state = stored.keepFocusOnSpaceSwitch ? .on : .off
        dryRunItem = item(menu, "Dry Run (log only)", #selector(toggleDryRun))
        menu.addItem(.separator())
        loginItem = item(menu, "Start at Login", #selector(toggleLoginItem))
        _ = item(menu, "Open Event Sink", #selector(openEventSink))
        _ = item(menu, "Open Logs Folder", #selector(openLogs))
        menu.addItem(.separator())
        _ = item(menu, "Quit TouchBridge", #selector(quit), key: "q")
        statusItem.menu = menu
        refreshTrackpadItems()
    }

    // MARK: trackpad settings

    private func refreshTrackpadItems() {
        let following = stored.followTrackpad
        followTrackpadItem.state = following ? .on : .off
        for (line, setting) in zip(trackpadLines, trackpad.settings) {
            line.title = setting.name.prefix(1).uppercased() + setting.name.dropFirst() + ": " + (setting.on ? "on" : "off")
            line.isHidden = !following
        }
        threeFingerItem.isEnabled = !following
        threeFingerItem.state = (following ? trackpad.threeFingerDrag : stored.threeFingerDrag) ? .on : .off
        threeFingerItem.title = following ? "Three-Finger Drag (from Trackpad settings)" : "Three-Finger Drag"
    }

    /// Re-reads the trackpad settings every few seconds and after wake (cfprefsd writes the plist lazily,
    /// so watching the file would miss changes).
    private func watchTrackpadSettings() {
        trackpadTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reloadTrackpadSettings() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.reloadTrackpadSettings() }
        }
    }

    private func reloadTrackpadSettings() {
        let latest = TrackpadPreferencesReader.read()
        guard latest != trackpad else { return }
        trackpad = latest
        log.write("trackpad settings changed: \(latest.summary)")
        refreshTrackpadItems()
        guard stored.followTrackpad else { return }
        pipeline.update { $0.trackpad = latest }
    }

    @objc private func toggleFollowTrackpad() {
        stored.followTrackpad.toggle()
        stored.save()
        let settings = stored, latest = trackpad
        pipeline.update { settings.apply(to: &$0, trackpad: latest) }
        refreshTrackpadItems()
        log.write("follow trackpad settings: \(stored.followTrackpad ? "on" : "off")")
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
        stored.delivery = forced
        stored.save()
        pipeline.update { $0.policy.forced = forced }
        log.write("delivery mode: \(forced.map(\.rawValue) ?? "automatic")")
    }

    @objc private func toggleGesturesDirect() {
        let on = gesturesDirectItem.state != .on
        gesturesDirectItem.state = on ? .on : .off
        stored.gesturesDirect = on
        stored.save()
        pipeline.update { $0.policy.gesturesDirect = on }
    }

    @objc private func toggleOneFingerScroll() {
        let on = oneFingerScrollItem.state != .on
        oneFingerScrollItem.state = on ? .on : .off
        stored.oneFingerScroll = on
        stored.save()
        pipeline.update { $0.oneFingerDrag = on ? .scroll : .clickAndDrag }
        log.write("one-finger drag: \(on ? "scroll" : "click-and-drag")")
    }

    @objc private func toggleReturnFocus() {
        let on = returnFocusItem.state != .on
        returnFocusItem.state = on ? .on : .off
        stored.returnFocus = on
        stored.save()
        pipeline.update { $0.focus = on ? .returnToPrevious : .followTouch }
        log.write("focus: \(on ? "return to previous app" : "follow touch")")
    }

    @objc private func toggleSwipePages() {
        let on = swipePagesItem.state != .on
        swipePagesItem.state = on ? .on : .off
        stored.swipeBetweenPages = on
        stored.save()
        pipeline.update { $0.swipeBetweenPages = on }
        log.write("swipe between pages: \(on ? "on" : "off")")
    }

    @objc private func toggleKeepFocus() {
        let on = keepFocusItem.state != .on
        keepFocusItem.state = on ? .on : .off
        stored.keepFocusOnSpaceSwitch = on
        stored.save()
        pipeline.update { $0.keepFocusOnSpaceSwitch = on }
        log.write("space switch: \(on ? "keeps focus on the other display" : "focus follows the switch")")
    }

    @objc private func toggleThreeFinger() {
        let on = threeFingerItem.state != .on
        threeFingerItem.state = on ? .on : .off
        stored.threeFingerDrag = on
        stored.save()
        pipeline.update { $0.threeFingerDrag = on }
        log.write("three-finger drag: \(on ? "on" : "off")")
    }

    @objc private func chooseAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let anchor = ThreeFingerAnchor(rawValue: raw) else { return }
        anchorItems.forEach { $0.state = $0 == sender ? .on : .off }
        stored.threeFingerAnchor = anchor
        stored.save()
        pipeline.update { $0.threeFingerAnchor = anchor }
        log.write("three-finger drag point: \(anchor.rawValue)")
    }

    @objc private func chooseTouchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = InputMode(rawValue: raw) else { return }
        touchModeItems.forEach { $0.state = $0 == sender ? .on : .off }
        pipeline.update { $0.inputMode = mode }
        // The menu-bar icon shows a special mode, so it isn't left on by accident.
        let symbol = switch mode {
        case .gestures: "hand.point.up.left"
        case .drawing: "pencil.tip"
        case .multitouch: "hand.raised.fingers.spread"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBridge")
            ?? NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchBridge")
        log.write("touch mode chosen: \(mode.rawValue)")
    }

    @objc private func chooseLaunchpadDock(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LaunchpadDockMode(rawValue: raw) else { return }
        launchpadItems.forEach { $0.state = $0 == sender ? .on : .off }
        stored.launchpadDock = mode
        stored.save()
        pipeline.update { $0.launchpadDock = mode }
        log.write("launchpad on the touch display: \(mode.rawValue)")
        if mode == .bringDockAndReturn { pipeline.returnDockHome() }
    }

    // MARK: login item

    private func refreshLoginItem() {
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItem.title = "Start at Login (restarts after a crash)"
    }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled { disableLoginItem() } else { _ = enableLoginItem() }
    }

    /// Registers the launchd agent and, unless launchd already runs this process, hands the panel over
    /// to it so a crash will be restarted. Returns true when this process is about to quit for the hand-over.
    private func enableLoginItem() -> Bool {
        do {
            try LoginItem.enable()
        } catch {
            log.write("login item: \(error.localizedDescription)")
            refreshLoginItem()
            return false
        }
        refreshLoginItem()
        log.write("login item: \(LoginItem.describe()) (\(LoginItem.plistURL.path))")
        guard !LoginItem.isLaunchdInstance else { return false }
        log.write("handing over to the login item")
        if running { pipeline.stop(); running = false }
        SingleInstance.release()
        LoginItem.handOverToLaunchd()
        NSApp.terminate(nil)
        return true
    }

    /// Unregistering stops the launchd job, so a login-item instance first starts a normal copy of itself.
    private func disableLoginItem() {
        guard LoginItem.isLaunchdInstance else {
            LoginItem.disable()
            refreshLoginItem()
            log.write("login item: \(LoginItem.describe())")
            return
        }
        log.write("login item off; continuing as a normal app")
        if running { pipeline.stop(); running = false }
        SingleInstance.release()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                LoginItem.disable()   // unloading the agent ends this process
                NSApp.terminate(nil)
            }
        }
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
        if LoginItem.isLaunchdInstance {
            // A failure exit makes launchd start a fresh process (which sees the new permission).
            SingleInstance.release()
            exit(1)
        }
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
