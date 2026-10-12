// InputInjector.swift
// MacLink – macOS Host
// Injects mouse, keyboard, and scroll events into the macOS event stream using
// Core Graphics (CGEvent).  Accessibility permission is required.

import Foundation
import CoreGraphics
import AppKit

final class InputInjector {

    private var isLeftMouseDown = false
    private var isRightMouseDown = false

    // MARK: - Mouse

    func injectMouseDelta(dx: Double, dy: Double, display: DisplayInfo) {
        guard let current = CGEvent(source: nil)?.location else { return }
        var newX = current.x + dx
        var newY = current.y + dy
        let maxX = Double(display.width)
        let maxY = Double(display.height)
        newX = max(0, min(maxX, newX))
        newY = max(0, min(maxY, newY))
        let point = CGPoint(x: newX, y: newY)

        let type: CGEventType
        if isLeftMouseDown {
            type = .leftMouseDragged
        } else if isRightMouseDown {
            type = .rightMouseDragged
        } else {
            type = .mouseMoved
        }

        let button: CGMouseButton = isRightMouseDown ? .right : .left
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: button)
        event?.post(tap: .cghidEventTap)
    }

    func injectMouseMove(normX: Double, normY: Double, display: DisplayInfo) {
        let point = toScreenPoint(normX: normX, normY: normY, display: display)
        let type: CGEventType
        if isLeftMouseDown {
            type = .leftMouseDragged
        } else if isRightMouseDown {
            type = .rightMouseDragged
        } else {
            type = .mouseMoved
        }
        let button: CGMouseButton = isRightMouseDown ? .right : .left
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: button)
        event?.post(tap: .cghidEventTap)
    }

    func injectMouseButton(_ payload: MouseButtonPayload, display: DisplayInfo) {
        let point: CGPoint
        if payload.normX < 0 || payload.normY < 0 {
            point = CGEvent(source: nil)?.location ?? toScreenPoint(normX: 0.5, normY: 0.5, display: display)
        } else {
            point = toScreenPoint(normX: payload.normX, normY: payload.normY, display: display)
        }

        let (downType, upType): (CGEventType, CGEventType)
        let cgButton: CGMouseButton
        switch payload.button {
        case .left:
            (downType, upType) = (.leftMouseDown, .leftMouseUp)
            cgButton = .left
            isLeftMouseDown = payload.pressed
        case .right:
            (downType, upType) = (.rightMouseDown, .rightMouseUp)
            cgButton = .right
            isRightMouseDown = payload.pressed
        case .middle:
            (downType, upType) = (.otherMouseDown, .otherMouseUp)
            cgButton = .center
        }

        let type = payload.pressed ? downType : upType
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(payload.clickCount))
        event?.post(tap: .cghidEventTap)
    }

    func injectScroll(_ payload: MouseScrollPayload) {
        // CGEventCreateScrollWheelEvent2 gives finer control
        // deltaY: positive = scroll up, negative = scroll down (macOS convention)
        let event = CGEvent(scrollWheelEvent2Source: nil,
                            units: .pixel,
                            wheelCount: 2,
                            wheel1: Int32(-payload.deltaY * 3),
                            wheel2: Int32(-payload.deltaX * 3),
                            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func injectKey(_ payload: KeyEventPayload) {
        let flags = CGEventFlags(rawValue: UInt64(payload.modifiers))
        let event = CGEvent(keyboardEventSource: nil,
                            virtualKey: payload.keyCode,
                            keyDown: payload.pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    func injectText(_ text: String) {
        // For plain text, type each character individually using CGEventKeyboardSetUnicodeString
        for char in text.unicodeScalars {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            var c = UniChar(char.value & 0xFFFF)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            event.post(tap: .cghidEventTap)

            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Coordinate conversion

    /// Convert normalised [0,1] coordinates from the captured frame to the physical
    /// screen coordinate (top-left origin, matching CGEvent expectations on macOS).
    private func toScreenPoint(normX: Double, normY: Double, display: DisplayInfo) -> CGPoint {
        let x = normX * Double(display.width)
        // CGEvent uses top-left origin; CGDisplayPixelsHigh gives physical height
        let y = normY * Double(display.height)
        return CGPoint(x: x, y: y)
    }
}
