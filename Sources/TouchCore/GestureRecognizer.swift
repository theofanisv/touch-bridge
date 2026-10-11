import Foundation

/// A position on the panel in its native orientation, normalized to 0...1.
public struct PanelPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum GesturePhase: Equatable, Sendable { case began, changed, ended }

/// The trackpad's system "dock swipes".
public enum DockSwipeKind: Equatable, Sendable {
    /// Four fingers left/right: Spaces and full-screen apps.
    case horizontal
    /// Four fingers up/down: Mission Control / App Exposé.
    case vertical
    /// Thumb and three or four fingers pinching in/out: Launchpad / Show Desktop.
    case pinch
}

/// What the user did, in panel coordinates. Delivery maps points and deltas onto the display.
public enum GestureAction: Equatable, Sendable {
    case tap(at: PanelPoint, count: Int)
    case rightClick(at: PanelPoint)
    /// `hold` is true when the finger rested before moving (drag-and-drop), which always uses Warp delivery.
    case dragBegan(at: PanelPoint, hold: Bool)
    case dragMoved(to: PanelPoint)
    case dragEnded(at: PanelPoint)
    /// Finger movement in normalized panel units; `.began` carries the movement since touch-down.
    case scroll(dx: Double, dy: Double, phase: GesturePhase)
    /// Lift velocity in normalized panel units per second, for momentum.
    case scrollEnded(velocityX: Double, velocityY: Double)
    /// Incremental magnification (0.1 = 10 % larger); `.began` carries the change since touch-down.
    case magnify(delta: Double, phase: GesturePhase)
    /// Incremental rotation in degrees, positive = counterclockwise as seen on screen.
    case rotate(degrees: Double, phase: GesturePhase)
    /// System gesture progress (1.0 ≈ a full swipe). Positive = Mission Control / Space on the right /
    /// Launchpad; negative = App Exposé / Space on the left / Show Desktop. `.began` carries the progress
    /// since touch-down; `.ended` lets the system complete or snap back.
    case dockSwipe(DockSwipeKind, delta: Double, phase: GesturePhase)
    /// A palm landed mid-swipe: snap the system gesture back.
    case dockSwipeCancelled(DockSwipeKind)
    /// Two fingers swiped in from the right edge.
    case notificationCenter
}

/// What a one-finger drag does (menu switch).
public enum OneFingerDragMode: String, Codable, Equatable, Sendable {
    /// Touch style: drag scrolls; press-and-hold then drag is click-and-drag.
    case scroll
    /// Mouse style: drag is click-and-drag; two fingers scroll.
    case clickAndDrag
}

/// Where a three-finger drag grabs (menu setting).
public enum ThreeFingerAnchor: String, Codable, Equatable, Sendable {
    /// The middle of the three fingers.
    case centroid
    /// Under the first finger that landed.
    case firstFinger
}

/// Thresholds for gesture classification. Distances are millimetres on the panel.
public struct GestureConfig: Codable, Equatable, Sendable {
    public var oneFingerDrag: OneFingerDragMode = .scroll
    /// Three fingers moving together = click-and-drag, like the trackpad's "Three-finger drag".
    public var threeFingerDrag = true
    public var threeFingerAnchor: ThreeFingerAnchor = .centroid
    /// The third finger must land within this time of the first.
    public var threeFingerWindowNs: UInt64 = 250_000_000
    /// Two-finger gestures that are switched on (trackpad settings).
    public var scrollEnabled = true
    public var pinchEnabled = true
    public var rotateEnabled = true
    /// System gestures that are switched on (trackpad settings).
    public var fourFingerVerticalSwipe = true
    public var fourFingerHorizontalSwipe = true
    public var fourFingerPinch = true
    public var notificationCenterSwipe = true
    /// Four or five fingers must all land within this time of the first.
    public var multiFingerWindowNs: UInt64 = 350_000_000
    public var maxMultiContacts = 5
    /// Travel before a four-finger gesture is classified, and how far a full swipe (progress 1.0) is.
    public var dockSwipeDecisionMm = 8.0
    public var dockSwipeMmPerUnit = 80.0
    public var dockPinchMmPerUnit = 40.0
    /// Two fingers starting this close to the panel's right edge and moving left this far open Notification Center.
    public var edgeZoneMm = 15.0
    public var edgeSwipeMm = 10.0
    public var panelWidthMm = 309.3
    public var panelHeightMm = 173.9
    public var tapSlopMm = 3.0
    public var doubleTapRadiusMm = 8.0
    public var doubleTapIntervalNs: UInt64 = 500_000_000
    public var longPressNs: UInt64 = 500_000_000
    public var twoFingerWindowNs: UInt64 = 150_000_000
    /// Finger travel before a two-finger gesture is classified.
    public var twoFingerDecisionMm = 4.0
    /// Fingers count as moving together when both moved at least this far, in directions this close (cosine).
    public var parallelMinMm = 1.5
    public var parallelMinCosine = 0.5
    /// Differential motion (fingers moving apart/together, or around each other) needed for pinch/rotate.
    public var pinchMinMm = 2.0
    public var rotateMinMm = 2.0
    public var maxContacts = 3
    public var velocityWindowNs: UInt64 = 100_000_000
    public var velocityStaleNs: UInt64 = 50_000_000

    public init() {}
}

/// Classifies contact events into gestures. Nothing is emitted until a gesture is classified,
/// so delivery can pick Direct or Warp once per gesture.
public struct GestureRecognizer: Sendable {
    private enum Lock: Sendable { case scroll, pinch, rotate, edge }

    private struct TwoFinger: Sendable {
        var ids: (UInt8, UInt8)
        /// When the first finger landed (a third finger must follow within threeFingerWindowNs).
        var firstDownNs: UInt64
        var start: [UInt8: PanelPoint]
        var positions: [UInt8: PanelPoint]
        var startCentroid: PanelPoint
        var startDistance: Double
        var startAngle: Double
        var lock: Lock?
        var lastCentroid: PanelPoint
        var lastDistance: Double
        var lastAngle: Double
        var samples: [(ns: UInt64, centroid: PanelPoint)]
    }

    private struct ThreeFinger: Sendable {
        /// The first finger to land comes first.
        var ids: [UInt8]
        var firstDownNs: UInt64
        var start: [UInt8: PanelPoint]
        var positions: [UInt8: PanelPoint]
        var dragging = false
        var lastAnchor: PanelPoint
    }

    private struct MultiFinger: Sendable {
        var ids: [UInt8]
        var firstDownNs: UInt64
        var start: [UInt8: PanelPoint]
        var positions: [UInt8: PanelPoint]
        var lock: DockSwipeKind?
        var lastCentroidMm: (x: Double, y: Double) = (0, 0)
        var lastSpreadMm = 0.0
    }

    private enum State: Sendable {
        case idle
        case oneFinger(id: UInt8, downNs: UInt64, origin: PanelPoint, current: PanelPoint)
        case dragging(id: UInt8, last: PanelPoint)
        /// One-finger scroll (scroll mode).
        case panning(id: UInt8, last: PanelPoint, samples: [(ns: UInt64, point: PanelPoint)])
        case twoFinger(TwoFinger)
        case threeFinger(ThreeFinger)
        case multiFinger(MultiFinger)
        /// Waits until every finger has lifted (after a two-finger gesture or a palm).
        case ignoring
    }

    private var config: GestureConfig
    private var state: State = .idle
    /// Answers "should a one-finger pan starting here be a click-and-drag even in scroll mode?"
    /// (the pipeline uses it for window title bars).
    public var dragZone: (@Sendable (PanelPoint) -> Bool)?
    public var oneFingerDrag: OneFingerDragMode {
        get { config.oneFingerDrag }
        set { config.oneFingerDrag = newValue }
    }
    public var threeFingerDrag: Bool {
        get { config.threeFingerDrag }
        set { config.threeFingerDrag = newValue }
    }
    public var threeFingerAnchor: ThreeFingerAnchor {
        get { config.threeFingerAnchor }
        set { config.threeFingerAnchor = newValue }
    }
    /// Follow the trackpad's gesture switches (three-finger drag, scroll, pinch, rotate).
    public mutating func apply(_ trackpad: TrackpadPreferences) {
        trackpad.apply(to: &config)
    }
    public mutating func enableAllTwoFingerGestures() {
        config.scrollEnabled = true
        config.pinchEnabled = true
        config.rotateEnabled = true
        config.fourFingerVerticalSwipe = true
        config.fourFingerHorizontalSwipe = true
        config.fourFingerPinch = true
        config.notificationCenterSwipe = true
    }
    private var active: [UInt8: PanelPoint] = [:]
    private var lastTap: (ns: UInt64, at: PanelPoint, count: Int)?
    private var twoFingerMoved = false
    private var threeFingerMoved = false
    private var multiFingerMoved = false

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    public mutating func handle(_ events: [ContactEvent], atNs now: UInt64) -> [GestureAction] {
        var actions: [GestureAction] = []
        twoFingerMoved = false
        threeFingerMoved = false
        multiFingerMoved = false
        for event in events {
            let point = PanelPoint(x: event.x, y: event.y)
            switch event.phase {
            case .began: active[event.id] = point
            case .moved: active[event.id] = point
            case .ended: active[event.id] = nil
            }
            if active.count > contactLimit {
                if event.phase == .began, let multi = startMultiFinger(event, point, now) {
                    state = .multiFinger(multi)
                    continue
                }
                actions += cancel()
                continue
            }
            actions += step(event, point, now)
            if active.isEmpty, case .ignoring = state { state = .idle }
        }
        // Both fingers of a frame move together; evaluate the two-finger gesture once per frame.
        if twoFingerMoved, case var .twoFinger(g) = state {
            actions += updateTwoFinger(&g, now)
            state = .twoFinger(g)
        }
        if threeFingerMoved, case var .threeFinger(t) = state {
            actions += updateThreeFinger(&t)
            state = .threeFinger(t)
        }
        if multiFingerMoved, case var .multiFinger(m) = state {
            actions += updateMultiFinger(&m)
            state = .multiFinger(m)
        }
        return actions
    }

    private mutating func step(_ event: ContactEvent, _ point: PanelPoint, _ now: UInt64) -> [GestureAction] {
        switch state {
        case .idle:
            if event.phase == .began {
                state = .oneFinger(id: event.id, downNs: now, origin: point, current: point)
            }
            return []

        case let .oneFinger(id, downNs, origin, current):
            if event.id != id {
                guard event.phase == .began, now - downNs <= config.twoFingerWindowNs else { return [] }
                state = .twoFinger(startTwoFinger(id, current, event.id, point, now, firstDownNs: downNs))
                return []
            }
            switch event.phase {
            case .moved where distanceMm(point, origin) > config.tapSlopMm:
                let hold = now - downNs >= config.longPressNs
                if !hold, config.oneFingerDrag == .scroll, !(dragZone?(origin) ?? false) {
                    state = .panning(id: id, last: point, samples: [(downNs, origin), (now, point)])
                    return [.scroll(dx: point.x - origin.x, dy: point.y - origin.y, phase: .began)]
                }
                state = .dragging(id: id, last: point)
                return [.dragBegan(at: origin, hold: hold), .dragMoved(to: point)]
            case .moved, .began:
                state = .oneFinger(id: id, downNs: downNs, origin: origin, current: point)
                return []
            case .ended:
                state = active.isEmpty ? .idle : .ignoring
                return now - downNs >= config.longPressNs ? [.rightClick(at: origin)] : [tap(at: origin, now)]
            }

        case let .dragging(id, last):
            guard event.id == id else { return [] }
            switch event.phase {
            case .moved:
                state = .dragging(id: id, last: point)
                return [.dragMoved(to: point)]
            case .ended:
                state = active.isEmpty ? .idle : .ignoring
                return [.dragEnded(at: point)]
            case .began:
                return [.dragEnded(at: last)]
            }

        case let .panning(id, last, samples):
            guard event.id == id else { return [] }
            switch event.phase {
            case .moved:
                var kept = samples.filter { now - $0.ns <= config.velocityWindowNs }
                kept.append((now, point))
                state = .panning(id: id, last: point, samples: kept)
                return [.scroll(dx: point.x - last.x, dy: point.y - last.y, phase: .changed)]
            case .ended:
                state = active.isEmpty ? .idle : .ignoring
                let v = velocity(samples, now)
                return [.scrollEnded(velocityX: v.x, velocityY: v.y)]
            case .began:
                return []
            }

        case var .twoFinger(g):
            if event.phase == .began, event.id != g.ids.0, event.id != g.ids.1, g.lock == nil,
               config.threeFingerDrag, now - g.firstDownNs <= config.threeFingerWindowNs,
               let a = g.positions[g.ids.0], let b = g.positions[g.ids.1] {
                let start = [g.ids.0: a, g.ids.1: b, event.id: point]
                let three = ThreeFinger(ids: [g.ids.0, g.ids.1, event.id], firstDownNs: g.firstDownNs, start: start, positions: start, lastAnchor: point)
                state = .threeFinger(three)
                return []
            }
            guard event.id == g.ids.0 || event.id == g.ids.1 else { return [] }
            if event.phase == .ended {
                state = active.isEmpty ? .idle : .ignoring
                return endTwoFinger(g, now)
            }
            g.positions[event.id] = point
            state = .twoFinger(g)
            twoFingerMoved = true
            return []

        case var .threeFinger(t):
            guard t.ids.contains(event.id) else { return [] }
            if event.phase == .ended {
                state = active.isEmpty ? .idle : .ignoring
                return t.dragging ? [.dragEnded(at: t.lastAnchor)] : []
            }
            t.positions[event.id] = point
            state = .threeFinger(t)
            threeFingerMoved = true
            return []

        case var .multiFinger(m):
            if event.phase == .began {
                // A fifth finger may still join while nothing has been classified.
                if m.lock == nil, !m.ids.contains(event.id), now - m.firstDownNs <= config.multiFingerWindowNs {
                    m.ids.append(event.id)
                    m.start[event.id] = point
                    m.positions[event.id] = point
                    state = .multiFinger(m)
                }
                return []
            }
            guard m.ids.contains(event.id) else { return [] }
            if event.phase == .ended {
                state = active.isEmpty ? .idle : .ignoring
                return m.lock.map { [.dockSwipe($0, delta: 0, phase: .ended)] } ?? []
            }
            m.positions[event.id] = point
            state = .multiFinger(m)
            multiFingerMoved = true
            return []

        case .ignoring:
            return []
        }
    }

    // MARK: four and five fingers (system dock swipes)

    /// More fingers than a one-, two- or three-finger gesture allows; four or five may form a dock swipe.
    private var contactLimit: Int {
        if case .multiFinger = state { config.maxMultiContacts } else { config.maxContacts }
    }

    /// A fourth finger joins three that landed together and haven't started a drag.
    private func startMultiFinger(_ event: ContactEvent, _ point: PanelPoint, _ now: UInt64) -> MultiFinger? {
        guard case let .threeFinger(t) = state, !t.dragging, active.count == config.maxContacts + 1,
              now - t.firstDownNs <= config.multiFingerWindowNs else { return nil }
        var start = t.positions
        start[event.id] = point
        var m = MultiFinger(ids: t.ids + [event.id], firstDownNs: t.firstDownNs, start: start, positions: start)
        m.lastCentroidMm = centroidMm(start)
        m.lastSpreadMm = spreadMm(start)
        return m
    }

    private func updateMultiFinger(_ m: inout MultiFinger) -> [GestureAction] {
        let points = m.positions.filter { m.ids.contains($0.key) }
        let centroid = centroidMm(points)
        let spread = spreadMm(points)
        defer { m.lastCentroidMm = centroid; m.lastSpreadMm = spread }
        guard let kind = m.lock else {
            let start = m.start.filter { m.ids.contains($0.key) }
            let c0 = centroidMm(start), s0 = spreadMm(start)
            let move = (x: centroid.x - c0.x, y: centroid.y - c0.y)
            let travel = hypot(move.x, move.y)
            let spreadChange = spread - s0
            // Coherence: all fingers but one must take part, so a hand settling doesn't trigger anything.
            let needed = m.ids.count - 1
            if abs(spreadChange) > config.dockSwipeDecisionMm, abs(spreadChange) > travel {
                let radial = m.ids.compactMap { id -> Double? in
                    guard let p = points[id], let p0 = start[id] else { return nil }
                    let r = hypot(p.x * config.panelWidthMm - centroid.x, p.y * config.panelHeightMm - centroid.y)
                    let r0 = hypot(p0.x * config.panelWidthMm - c0.x, p0.y * config.panelHeightMm - c0.y)
                    return r - r0
                }
                guard radial.filter({ ($0 < 0) == (spreadChange < 0) && abs($0) >= 2 }).count >= needed else { return [] }
                guard config.fourFingerPinch else { return [] }
                m.lock = .pinch
                return [.dockSwipe(.pinch, delta: -spreadChange / config.dockPinchMmPerUnit, phase: .began)]
            }
            guard travel > config.dockSwipeDecisionMm else { return [] }
            let direction = (x: move.x / travel, y: move.y / travel)
            let along = m.ids.filter { id in
                guard let p = points[id], let p0 = start[id] else { return false }
                let d = (x: (p.x - p0.x) * config.panelWidthMm, y: (p.y - p0.y) * config.panelHeightMm)
                return d.x * direction.x + d.y * direction.y >= config.dockSwipeDecisionMm / 2
            }
            guard along.count >= needed else { return [] }
            if abs(move.y) >= abs(move.x) {
                guard config.fourFingerVerticalSwipe else { return [] }
                m.lock = .vertical
                return [.dockSwipe(.vertical, delta: -move.y / config.dockSwipeMmPerUnit, phase: .began)]
            }
            guard config.fourFingerHorizontalSwipe else { return [] }
            m.lock = .horizontal
            return [.dockSwipe(.horizontal, delta: -move.x / config.dockSwipeMmPerUnit, phase: .began)]
        }
        let delta: Double = switch kind {
        case .vertical: -(centroid.y - m.lastCentroidMm.y) / config.dockSwipeMmPerUnit
        case .horizontal: -(centroid.x - m.lastCentroidMm.x) / config.dockSwipeMmPerUnit
        case .pinch: -(spread - m.lastSpreadMm) / config.dockPinchMmPerUnit
        }
        return delta == 0 ? [] : [.dockSwipe(kind, delta: delta, phase: .changed)]
    }

    private func centroidMm(_ points: [UInt8: PanelPoint]) -> (x: Double, y: Double) {
        let c = centroid(points)
        return (c.x * config.panelWidthMm, c.y * config.panelHeightMm)
    }

    /// Mean distance of the fingers from their centre, in millimetres.
    private func spreadMm(_ points: [UInt8: PanelPoint]) -> Double {
        let c = centroidMm(points)
        let distances = points.values.map { hypot($0.x * config.panelWidthMm - c.x, $0.y * config.panelHeightMm - c.y) }
        return distances.reduce(0, +) / Double(max(distances.count, 1))
    }

    // MARK: three fingers

    /// Three fingers moving together drag (like the trackpad setting), from their centre or the first finger.
    private func updateThreeFinger(_ t: inout ThreeFinger) -> [GestureAction] {
        let anchor = anchorPoint(t.positions, first: t.ids[0])
        if !t.dragging {
            guard distanceMm(centroid(t.positions), centroid(t.start)) > config.twoFingerDecisionMm else { return [] }
            t.dragging = true
            t.lastAnchor = anchor
            return [.dragBegan(at: anchorPoint(t.start, first: t.ids[0]), hold: true), .dragMoved(to: anchor)]
        }
        guard anchor != t.lastAnchor else { return [] }
        t.lastAnchor = anchor
        return [.dragMoved(to: anchor)]
    }

    private func anchorPoint(_ points: [UInt8: PanelPoint], first: UInt8) -> PanelPoint {
        switch config.threeFingerAnchor {
        case .centroid: centroid(points)
        case .firstFinger: points[first] ?? centroid(points)
        }
    }

    private func centroid(_ points: [UInt8: PanelPoint]) -> PanelPoint {
        let n = Double(max(points.count, 1))
        return PanelPoint(x: points.values.map(\.x).reduce(0, +) / n, y: points.values.map(\.y).reduce(0, +) / n)
    }

    // MARK: taps

    private mutating func tap(at point: PanelPoint, _ now: UInt64) -> GestureAction {
        if let last = lastTap, now - last.ns <= config.doubleTapIntervalNs, distanceMm(point, last.at) <= config.doubleTapRadiusMm {
            lastTap = (now, last.at, last.count + 1)
            return .tap(at: last.at, count: last.count + 1)
        }
        lastTap = (now, point, 1)
        return .tap(at: point, count: 1)
    }

    // MARK: two fingers

    private func startTwoFinger(_ a: UInt8, _ pa: PanelPoint, _ b: UInt8, _ pb: PanelPoint, _ now: UInt64, firstDownNs: UInt64) -> TwoFinger {
        let centroid = midpoint(pa, pb)
        let distance = distanceMm(pa, pb)
        let angle = angleDegrees(pa, pb)
        return TwoFinger(
            ids: (a, b), firstDownNs: firstDownNs, start: [a: pa, b: pb], positions: [a: pa, b: pb],
            startCentroid: centroid, startDistance: distance, startAngle: angle, lock: nil,
            lastCentroid: centroid, lastDistance: distance, lastAngle: angle,
            samples: [(now, centroid)]
        )
    }

    private func updateTwoFinger(_ g: inout TwoFinger, _ now: UInt64) -> [GestureAction] {
        guard let pa = g.positions[g.ids.0], let pb = g.positions[g.ids.1] else { return [] }
        let centroid = midpoint(pa, pb)
        let distance = distanceMm(pa, pb)
        let angle = angleDegrees(pa, pb)
        g.samples.append((now, centroid))
        g.samples.removeAll { now - $0.ns > config.velocityWindowNs }
        defer { g.lastCentroid = centroid; g.lastDistance = distance; g.lastAngle = angle }

        switch g.lock {
        case nil:
            guard let lock = classify(g, pa, pb) else { return [] }
            g.lock = lock
            switch lock {
            case .edge:
                return [.notificationCenter]
            case .scroll:
                return [.scroll(dx: centroid.x - g.startCentroid.x, dy: centroid.y - g.startCentroid.y, phase: .began)]
            case .pinch:
                return g.startDistance > 0 ? [.magnify(delta: distance / g.startDistance - 1, phase: .began)] : []
            case .rotate:
                return [.rotate(degrees: counterclockwise(from: g.startAngle, to: angle), phase: .began)]
            }
        case .scroll:
            return [.scroll(dx: centroid.x - g.lastCentroid.x, dy: centroid.y - g.lastCentroid.y, phase: .changed)]
        case .pinch:
            return g.lastDistance > 0 ? [.magnify(delta: distance / g.lastDistance - 1, phase: .changed)] : []
        case .rotate:
            return [.rotate(degrees: counterclockwise(from: g.lastAngle, to: angle), phase: .changed)]
        case .edge:
            return []
        }
    }

    private func endTwoFinger(_ g: TwoFinger, _ now: UInt64) -> [GestureAction] {
        switch g.lock {
        case nil, .edge: return []
        case .pinch: return [.magnify(delta: 0, phase: .ended)]
        case .rotate: return [.rotate(degrees: 0, phase: .ended)]
        case .scroll:
            let v = velocity(g.samples.map { ($0.ns, $0.centroid) }, now)
            return [.scrollEnded(velocityX: v.x, velocityY: v.y)]
        }
    }

    /// Classifies by how the fingers move (like the trackpad): both the same way → scroll;
    /// toward/away from each other → pinch; around each other → rotate. Nil until clear.
    private func classify(_ g: TwoFinger, _ pa: PanelPoint, _ pb: PanelPoint) -> Lock? {
        guard let sa = g.start[g.ids.0], let sb = g.start[g.ids.1] else { return nil }
        let da = mmVector(sa, pa), db = mmVector(sb, pb)
        let ma = hypot(da.x, da.y), mb = hypot(db.x, db.y)
        guard max(ma, mb) > config.twoFingerDecisionMm else { return nil }

        let axis = mmVector(sb, sa)
        let length = hypot(axis.x, axis.y)
        guard length > 0 else { return .scroll }
        let ux = axis.x / length, uy = axis.y / length
        let common = (x: (da.x + db.x) / 2, y: (da.y + db.y) / 2)
        let differential = (x: (da.x - db.x) / 2, y: (da.y - db.y) / 2)
        let radial = abs(differential.x * ux + differential.y * uy)
        let tangential = abs(differential.x * uy - differential.y * ux)

        let together = min(ma, mb) >= config.parallelMinMm && (da.x * db.x + da.y * db.y) / (ma * mb) > config.parallelMinCosine
        // Two fingers starting near the right edge and moving mostly left: Notification Center. The fingers
        // may move unevenly (owner report: stacked fingers were taken for rotate); waits for enough travel.
        if config.notificationCenterSwipe, common.x < 0, abs(common.x) > 2 * abs(common.y),
           (1 - (sa.x + sb.x) / 2) * config.panelWidthMm <= config.edgeZoneMm {
            return abs(common.x) > config.edgeSwipeMm ? .edge : nil
        }
        if together, hypot(common.x, common.y) > max(radial, tangential) { return config.scrollEnabled ? .scroll : nil }
        if radial >= tangential { return radial >= config.pinchMinMm && config.pinchEnabled ? .pinch : nil }
        return tangential >= config.rotateMinMm && config.rotateEnabled ? .rotate : nil
    }

    /// Velocity over the recent samples, in normalized panel units per second; zero if the finger had stopped.
    private func velocity(_ samples: [(ns: UInt64, point: PanelPoint)], _ now: UInt64) -> (x: Double, y: Double) {
        guard let first = samples.first, let last = samples.last,
              last.ns > first.ns, now - last.ns <= config.velocityStaleNs else { return (0, 0) }
        let seconds = Double(last.ns - first.ns) / 1e9
        return ((last.point.x - first.point.x) / seconds, (last.point.y - first.point.y) / seconds)
    }

    // MARK: palm

    private mutating func cancel() -> [GestureAction] {
        let actions: [GestureAction]
        switch state {
        case let .dragging(_, last): actions = [.dragEnded(at: last)]
        case let .threeFinger(t) where t.dragging: actions = [.dragEnded(at: t.lastAnchor)]
        case let .multiFinger(m) where m.lock != nil: actions = [.dockSwipeCancelled(m.lock!)]
        case .panning: actions = [.scrollEnded(velocityX: 0, velocityY: 0)]
        case let .twoFinger(g) where g.lock == .scroll: actions = [.scrollEnded(velocityX: 0, velocityY: 0)]
        case let .twoFinger(g) where g.lock == .pinch: actions = [.magnify(delta: 0, phase: .ended)]
        case let .twoFinger(g) where g.lock == .rotate: actions = [.rotate(degrees: 0, phase: .ended)]
        default: actions = []
        }
        state = .ignoring
        return actions
    }

    // MARK: geometry (millimetres, so the panel's aspect ratio doesn't skew distances or angles)

    private func mmVector(_ from: PanelPoint, _ to: PanelPoint) -> (x: Double, y: Double) {
        ((to.x - from.x) * config.panelWidthMm, (to.y - from.y) * config.panelHeightMm)
    }

    private func distanceMm(_ a: PanelPoint, _ b: PanelPoint) -> Double {
        hypot((a.x - b.x) * config.panelWidthMm, (a.y - b.y) * config.panelHeightMm)
    }

    private func angleDegrees(_ a: PanelPoint, _ b: PanelPoint) -> Double {
        atan2((b.y - a.y) * config.panelHeightMm, (b.x - a.x) * config.panelWidthMm) * 180 / .pi
    }

    /// Screen y grows downward, so a counterclockwise turn decreases the atan2 angle.
    private func counterclockwise(from start: Double, to end: Double) -> Double {
        var delta = start - end
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func midpoint(_ a: PanelPoint, _ b: PanelPoint) -> PanelPoint {
        PanelPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
