import AppKit
import ServiceManagement

/// "Start at Login": a classic per-user launch agent (~/Library/LaunchAgents) that runs the installed
/// app's executable by path. launchd starts TouchBridge at login and restarts it after a crash; a normal
/// Quit (exit 0) stays quit until the next login.
///
/// Not SMAppService: it pins the exact build it registered (bundle identity and code signature), so every
/// rebuild of this self-signed app broke the login item (2026-10-10, see ledger).
@MainActor
enum LoginItem {
    static let label = "com.theofanis.touchbridge.agent"
    /// The earlier SMAppService registration (bundle plist), removed on startup if still present.
    private static let legacyPlistName = "com.theofanis.touchbridge.plist"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }
    private static var service: String { "gui/\(getuid())/\(label)" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// True when this process was started by the launch agent (so a crash will be restarted).
    static var isLaunchdInstance: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Writes the agent for this copy of the app and loads it (launchd starts it: RunAtLoad).
    static func enable() throws {
        guard let executable = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let logs = FileLog.directory.path
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "LimitLoadToSessionType": ["Aqua"],
            "ProcessType": "Interactive",
            "StandardOutPath": "\(logs)/agent.log",
            "StandardErrorPath": "\(logs)/agent.log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        launchctl("bootout", service)
        launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
    }

    /// Unloads the agent (stopping a launchd-run instance) and removes it.
    static func disable() {
        launchctl("bootout", service)
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func describe() -> String {
        guard isEnabled else { return "off" }
        return isLaunchdInstance ? "on (running as login item)" : "on"
    }

    /// Hands the panel over to the agent: start it a moment after this process exits.
    static func handOverToLaunchd() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /bin/launchctl kickstart \(service)"]
        try? task.run()
    }

    /// Removes the earlier SMAppService login item, which can no longer start rebuilt copies.
    static func removeLegacyRegistration() -> Bool {
        let legacy = SMAppService.agent(plistName: legacyPlistName)
        guard legacy.status == .enabled || legacy.status == .requiresApproval else { return false }
        try? legacy.unregister()
        return true
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
