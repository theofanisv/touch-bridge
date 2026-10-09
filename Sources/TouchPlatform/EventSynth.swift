import CoreGraphics
import Foundation

/// Builds the synthetic CGEvents TouchBridge posts. Field numbers are from CGEventTypes.h unless marked private.
enum EventSynth {
    /// Written to kCGEventSourceUserData (field 42) so our own events can be recognised ("TBGR").
    static let tag: Int64 = 0x5442_4752

    private static let windowUnderPointer = CGEventField(rawValue: 91)!                // kCGMouseEventWindowUnderMousePointer
    private static let windowThatCanHandle = CGEventField(rawValue: 92)!               // …ThatCanHandleThisEvent
    private static let scrollPhase = CGEventField(rawValue: 99)!                       // bitmask: 1 began, 2 changed, 4 ended
    private static let momentumPhase = CGEventField(rawValue: 123)!                    // 0 none, 1 begin, 2 continue, 3 end
    // Private gesture fields (as used by Mac Mouse Fix's TouchSimulator.m).
    private static let eventType = CGEventField(rawValue: 55)!
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let gestureZoomValue = CGEventField(rawValue: 113)!
    private static let gestureRotationValue = CGEventField(rawValue: 114)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let nsEventTypeGesture: Int64 = 29
    private static let hidTypeZoom: Int64 = 8
    private static let hidTypeRotation: Int64 = 5

    enum Phase { case began, changed, ended }
    enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

    static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, eventNumber: Int64,
                      window: Int?, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        finish(event, window: window)
        return event
    }

    /// `dx`/`dy` in points; positive dy scrolls content down (as when a finger drags the page down).
    static func scroll(dx: Double, dy: Double, at point: CGPoint, phase: Phase?, momentum: MomentumPhase,
                       window: Int?, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        event.setIntegerValueField(scrollPhase, value: phase.map(phaseMask) ?? 0)
        event.setIntegerValueField(momentumPhase, value: momentum.rawValue)
        finish(event, window: window)
        return event
    }

    static func magnify(_ delta: Double, at point: CGPoint, phase: Phase, window: Int?, source: CGEventSource?) -> CGEvent? {
        gesture(hidType: hidTypeZoom, valueField: gestureZoomValue, value: delta, at: point, phase: phase, window: window, source: source)
    }

    /// Degrees, positive = counterclockwise.
    static func rotate(_ degrees: Double, at point: CGPoint, phase: Phase, window: Int?, source: CGEventSource?) -> CGEvent? {
        gesture(hidType: hidTypeRotation, valueField: gestureRotationValue, value: degrees, at: point, phase: phase, window: window, source: source)
    }

    private static func gesture(hidType: Int64, valueField: CGEventField, value: Double, at point: CGPoint, phase: Phase,
                                window: Int?, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.setIntegerValueField(eventType, value: nsEventTypeGesture)
        event.location = point
        event.setIntegerValueField(gestureHIDType, value: hidType)
        event.setDoubleValueField(valueField, value: value)
        event.setIntegerValueField(gesturePhase, value: phaseMask(phase))
        finish(event, window: window)
        return event
    }

    private static func phaseMask(_ phase: Phase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        }
    }

    private static func finish(_ event: CGEvent, window: Int?) {
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.flags = CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if let window {
            event.setIntegerValueField(windowUnderPointer, value: Int64(window))
            event.setIntegerValueField(windowThatCanHandle, value: Int64(window))
        }
    }
}
