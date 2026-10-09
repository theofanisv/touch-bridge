import Testing
@testable import TouchCore

@Test func slowLiftHasNoMomentum() {
    var m = Momentum(velocityX: 5, velocityY: -5)
    let step = m.next()
    #expect(step == nil)
}

@Test func firstStepIsVelocityTimesFrameInterval() throws {
    var m = Momentum(velocityX: 0, velocityY: 1200, frameInterval: 1.0 / 120)
    let first = m.next()
    let step = try #require(first)
    #expect(abs(step.dx) < 1e-9)
    #expect(abs(step.dy - 10) < 1e-9)
}

@Test func stepsDecayAndEventuallyStop() {
    var m = Momentum(velocityX: 3000, velocityY: 0, frameInterval: 1.0 / 120, decay: 0.95, minSpeed: 20)
    var steps: [Double] = []
    while let step = m.next() { steps.append(step.dx) }
    #expect(steps.count > 10 && steps.count < 200)
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 })
    let total = steps.reduce(0, +)
    #expect(total < 3000.0 / 120 / (1 - 0.95))  // bounded by the geometric series
}
