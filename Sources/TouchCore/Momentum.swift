import Foundation

/// Scroll momentum after a two-finger flick: per-frame deltas (points) that decay geometrically.
public struct Momentum: Sendable {
    private var vx: Double
    private var vy: Double
    private let frameInterval: Double
    private let decay: Double
    private let minSpeed: Double

    /// Velocities in points per second.
    public init(velocityX: Double, velocityY: Double, frameInterval: Double = 1.0 / 120, decay: Double = 0.95, minSpeed: Double = 20) {
        vx = velocityX
        vy = velocityY
        self.frameInterval = frameInterval
        self.decay = decay
        self.minSpeed = minSpeed
    }

    /// The next frame's delta, or nil once the motion has died out.
    public mutating func next() -> (dx: Double, dy: Double)? {
        guard hypot(vx, vy) >= minSpeed else { return nil }
        let step = (dx: vx * frameInterval, dy: vy * frameInterval)
        vx *= decay
        vy *= decay
        return step
    }
}
