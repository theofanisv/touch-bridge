/// Holds a dock swipe's first steps back while something is prepared (the Dock brought to the touch display
/// before Launchpad opens), then releases them as one `began` step.
public struct DockSwipeHold: Sendable {
    public struct Step: Equatable, Sendable {
        public let delta: Double
        public let phase: GesturePhase
    }

    public private(set) var isHolding = false
    private var held = 0.0
    private var began = false
    private var ended = false

    public init() {}

    public mutating func start() {
        isHolding = true
        held = 0
        began = false
        ended = false
    }

    /// While holding, keeps the step; otherwise returns it to be posted now.
    public mutating func pass(_ delta: Double, _ phase: GesturePhase) -> [Step] {
        guard isHolding else { return [Step(delta: delta, phase: phase)] }
        switch phase {
        case .began: began = true; held = delta
        case .changed: held += delta
        case .ended: ended = true
        }
        return []
    }

    /// Ends the hold: the held steps merged into one `began`, plus `ended` if the fingers already lifted.
    public mutating func release() -> [Step] {
        guard isHolding else { return [] }
        isHolding = false
        guard began else { return [] }
        return ended ? [Step(delta: held, phase: .began), Step(delta: 0, phase: .ended)] : [Step(delta: held, phase: .began)]
    }

    /// Drops a held swipe. True when nothing had reached the system yet (so there is nothing to cancel).
    public mutating func cancel() -> Bool {
        guard isHolding else { return false }
        isHolding = false
        return true
    }
}
