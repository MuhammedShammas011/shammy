// MacLinkProtocolTests.swift
// Unit tests for message framing and encoding/decoding.
// Run with: swift test

import XCTest
@testable import MacLinkProtocol

final class FramingTests: XCTestCase {

    func testRoundTripMouseMove() throws {
        let msg = ControlMessage(type: .mouseMove,
                                  payload: .mouseMove(MouseMovePayload(normX: 0.5, normY: 0.3)))
        let data = try MessageFramer.encode(msg)
        var buf = data
        let decoded = try MessageFramer.decode(from: &buf)
        XCTAssertEqual(decoded.count, 1)
        let first = decoded[0]
        XCTAssertEqual(first.type, .mouseMove)
        if case .mouseMove(let p) = first.payload {
            XCTAssertEqual(p.normX, 0.5, accuracy: 0.001)
            XCTAssertEqual(p.normY, 0.3, accuracy: 0.001)
        } else {
            XCTFail("Expected mouseMove payload")
        }
    }

    func testRoundTripKeyEvent() throws {
        let msg = ControlMessage(type: .keyDown,
                                  payload: .keyEvent(KeyEventPayload(
                                    keyCode: MacKeyCode.c.rawValue,
                                    pressed: true,
                                    modifiers: ModifierFlag.command.rawValue)))
        let data = try MessageFramer.encode(msg)
        var buf = data
        let decoded = try MessageFramer.decode(from: &buf)
        XCTAssertEqual(decoded.count, 1)
        if case .keyEvent(let p) = decoded[0].payload {
            XCTAssertEqual(p.keyCode, MacKeyCode.c.rawValue)
            XCTAssertTrue(p.pressed)
            XCTAssertEqual(p.modifiers, ModifierFlag.command.rawValue)
        } else {
            XCTFail("Expected keyEvent payload")
        }
    }

    func testMultipleMessagesInBuffer() throws {
        let m1 = ControlMessage(type: .ping, payload: .ping(PingPayload()))
        let m2 = ControlMessage(type: .mouseMove,
                                 payload: .mouseMove(MouseMovePayload(normX: 0.1, normY: 0.9)))
        var buf = Data()
        buf.append(try MessageFramer.encode(m1))
        buf.append(try MessageFramer.encode(m2))
        let decoded = try MessageFramer.decode(from: &buf)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].type, .ping)
        XCTAssertEqual(decoded[1].type, .mouseMove)
        XCTAssertTrue(buf.isEmpty)
    }

    func testPartialBufferWaitsForMoreData() throws {
        let msg = ControlMessage(type: .ping, payload: .ping(PingPayload()))
        let data = try MessageFramer.encode(msg)
        var buf = data.prefix(6)    // truncated — less than the full message
        let decoded = try MessageFramer.decode(from: &buf)
        XCTAssertEqual(decoded.count, 0)
        XCTAssertEqual(buf.count, 6)   // buffer unchanged
    }

    func testHelloRoundTrip() throws {
        let msg = ControlMessage(type: .hello,
                                  payload: .hello(HelloPayload(
                                    appVersion: "1.0.0",
                                    platform: "ios",
                                    deviceName: "iPhone 15 Pro",
                                    supportedFeatures: ["video", "input"])))
        let data = try MessageFramer.encode(msg)
        var buf = data
        let decoded = try MessageFramer.decode(from: &buf)
        XCTAssertEqual(decoded.count, 1)
        if case .hello(let p) = decoded[0].payload {
            XCTAssertEqual(p.deviceName, "iPhone 15 Pro")
            XCTAssertEqual(p.supportedFeatures, ["video", "input"])
        } else {
            XCTFail("Expected hello payload")
        }
    }
}
