/// What to do about the Dock when Launchpad is opened from the touch display. Launchpad opens on the
/// display that has the Dock (`--system-ui-selftest`, 2026-10-11).
public enum LaunchpadDockMode: String, Codable, CaseIterable, Sendable {
    /// Bring the Dock to the touch display first; it stays there, as if moved there by hand.
    case bringDock
    /// Bring the Dock over, then push it back once Launchpad has closed (the default: the trackpad keeps
    /// opening Launchpad on the other display).
    case bringDockAndReturn
    /// Leave the Dock alone; Launchpad opens wherever the Dock is.
    case leave
}

public enum LaunchpadDock {
    public struct Plan: Equatable, Sendable {
        /// Push the Dock to the touch display before Launchpad opens.
        public let bringDock: Bool
        /// Push it home once Launchpad has closed: with "then back" the Dock lives off the touch display,
        /// wherever it was found (owner report 2026-10-11: one left there earlier never went back).
        public let returnDock: Bool

        public init(bringDock: Bool, returnDock: Bool) {
            self.bringDock = bringDock
            self.returnDock = returnDock
        }
    }

    /// Pinching in opens Launchpad; spreading shows the desktop, which covers every display anyway.
    public static func plan(mode: LaunchpadDockMode, pinchInward: Bool, dockOnTouchDisplay: Bool) -> Plan {
        guard pinchInward else { return Plan(bringDock: false, returnDock: false) }
        switch mode {
        case .bringDock: return Plan(bringDock: !dockOnTouchDisplay, returnDock: false)
        case .bringDockAndReturn: return Plan(bringDock: !dockOnTouchDisplay, returnDock: true)
        case .leave: return Plan(bringDock: false, returnDock: false)
        }
    }

    /// Where "then back" returns the Dock: the display it was on, or, when it was already on the touch
    /// display, the main display (or any other one if the touch display is the main one).
    public static func home(dock: ScreenPoint, touch: ScreenRect, displays: [ScreenRect], main: ScreenRect?) -> ScreenRect? {
        if let current = displays.first(where: { $0 != touch && $0.contains(dock) }) { return current }
        if let main, main != touch { return main }
        return displays.first { $0 != touch }
    }
}

/// "Bring the Dock over, then back": polled about every 250 ms after the Dock was brought over, it says when
/// to push the Dock back. That is once Launchpad has closed (two closed polls in a row, so a flicker doesn't
/// count) or never opened within 2 s, and only while no finger is on the panel (the push moves the cursor).
public struct DockReturnWatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case wait, pushBack, stop }

    static let notOpenedTimeoutNs: UInt64 = 2_000_000_000
    static let closedPollsNeeded = 2
    static let maxWatchNs: UInt64 = 600_000_000_000

    private let startedNs: UInt64
    private var sawOpen = false
    private var closedPolls = 0

    public init(startedNs: UInt64) {
        self.startedNs = startedNs
    }

    public mutating func poll(launchpadOpen: Bool, fingersDown: Bool, atNs now: UInt64) -> Action {
        let elapsed = now &- startedNs
        if elapsed >= Self.maxWatchNs { return .stop }
        if launchpadOpen {
            sawOpen = true
            closedPolls = 0
            return .wait
        }
        closedPolls += 1
        let gone = sawOpen ? closedPolls >= Self.closedPollsNeeded : elapsed >= Self.notOpenedTimeoutNs
        return gone && !fingersDown ? .pushBack : .wait
    }
}
