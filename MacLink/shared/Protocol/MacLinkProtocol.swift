// MacLinkProtocol.swift
// Shared message types used by both the macOS host and iOS client.
// Transport is plain TCP + length-prefixed JSON frames over the Tailscale/LAN interface.
// Video frames are delivered separately via WebRTC (or direct RTP over the same socket
// depending on the chosen transport path).

import Foundation

// MARK: - Wire frame envelope

/// Every message sent on the control socket is prefixed with a 4-byte big-endian
/// length field that describes the number of bytes in the following JSON payload.
/// This makes framing simple and language-agnostic.

// MARK: - Message direction

public enum MessageDirection {
    case hostToClient   // Mac  → iPhone
    case clientToHost   // iPhone → Mac
    case bidirectional
}

// MARK: - Control message types

public enum ControlMessageType: String, Codable {
    // Handshake
    case hello              // client introduces itself
    case helloAck           // host acknowledges, sends capabilities
    case authChallenge      // host issues a random token (future: PIN auth)
    case authResponse       // client echoes the token (same-secret scheme)
    case authResult         // host confirms authentication

    // Session lifecycle
    case startSession       // client requests control start
    case sessionStarted     // host confirms session is live
    case stopSession        // either side terminates the session
    case sessionStopped     // acknowledgement of stop

    // Input events  (client → host)
    case mouseMove
    case mouseDown
    case mouseUp
    case mouseScroll
    case keyDown
    case keyUp
    case textInput          // paste-style bulk text input

    // Display info  (host → client)
    case displayInfo        // screen dimensions, scale factor
    case displayChanged     // display geometry changed mid-session

    // Quality control (bidirectional)
    case qualityRequest     // client requests a quality change
    case qualityAck         // host acknowledges

    // Diagnostics
    case ping
    case pong
    case error
}

// MARK: - Top-level envelope

public struct ControlMessage: Codable {
    public let type: ControlMessageType
    public let id: String           // UUID for request/response pairing
    public let timestamp: Double    // Unix timestamp (seconds)
    public let payload: Payload?

    public init(type: ControlMessageType, payload: Payload? = nil) {
        self.type = type
        self.id = UUID().uuidString
        self.timestamp = Date().timeIntervalSince1970
        self.payload = payload
    }
}

// MARK: - Payload variants

public extension ControlMessage {

    enum Payload: Codable {

        // --- Handshake ---
        case hello(HelloPayload)
        case helloAck(HelloAckPayload)
        case authChallenge(AuthChallengePayload)
        case authResponse(AuthResponsePayload)
        case authResult(AuthResultPayload)

        // --- Session ---
        case sessionInfo(SessionInfoPayload)
        case displayInfo(DisplayInfoPayload)

        // --- Input ---
        case mouseMove(MouseMovePayload)
        case mouseButton(MouseButtonPayload)
        case mouseScroll(MouseScrollPayload)
        case keyEvent(KeyEventPayload)
        case textInput(TextInputPayload)

        // --- Quality ---
        case qualityRequest(QualityRequestPayload)

        // --- Error ---
        case error(ErrorPayload)

        // --- Ping/Pong ---
        case ping(PingPayload)
        case pong(PongPayload)

        // MARK: Custom Coding

        private enum CodingKeys: String, CodingKey {
            case kind, data
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "hello":           self = .hello(try c.decode(HelloPayload.self, forKey: .data))
            case "helloAck":        self = .helloAck(try c.decode(HelloAckPayload.self, forKey: .data))
            case "authChallenge":   self = .authChallenge(try c.decode(AuthChallengePayload.self, forKey: .data))
            case "authResponse":    self = .authResponse(try c.decode(AuthResponsePayload.self, forKey: .data))
            case "authResult":      self = .authResult(try c.decode(AuthResultPayload.self, forKey: .data))
            case "sessionInfo":     self = .sessionInfo(try c.decode(SessionInfoPayload.self, forKey: .data))
            case "displayInfo":     self = .displayInfo(try c.decode(DisplayInfoPayload.self, forKey: .data))
            case "mouseMove":       self = .mouseMove(try c.decode(MouseMovePayload.self, forKey: .data))
            case "mouseButton":     self = .mouseButton(try c.decode(MouseButtonPayload.self, forKey: .data))
            case "mouseScroll":     self = .mouseScroll(try c.decode(MouseScrollPayload.self, forKey: .data))
            case "keyEvent":        self = .keyEvent(try c.decode(KeyEventPayload.self, forKey: .data))
            case "textInput":       self = .textInput(try c.decode(TextInputPayload.self, forKey: .data))
            case "qualityRequest":  self = .qualityRequest(try c.decode(QualityRequestPayload.self, forKey: .data))
            case "error":           self = .error(try c.decode(ErrorPayload.self, forKey: .data))
            case "ping":            self = .ping(try c.decode(PingPayload.self, forKey: .data))
            case "pong":            self = .pong(try c.decode(PongPayload.self, forKey: .data))
            default: throw DecodingError.dataCorruptedError(forKey: .kind,
                                                             in: c,
                                                             debugDescription: "Unknown payload kind: \(kind)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hello(let p):         try c.encode("hello", forKey: .kind);          try c.encode(p, forKey: .data)
            case .helloAck(let p):      try c.encode("helloAck", forKey: .kind);       try c.encode(p, forKey: .data)
            case .authChallenge(let p): try c.encode("authChallenge", forKey: .kind);  try c.encode(p, forKey: .data)
            case .authResponse(let p):  try c.encode("authResponse", forKey: .kind);   try c.encode(p, forKey: .data)
            case .authResult(let p):    try c.encode("authResult", forKey: .kind);     try c.encode(p, forKey: .data)
            case .sessionInfo(let p):   try c.encode("sessionInfo", forKey: .kind);    try c.encode(p, forKey: .data)
            case .displayInfo(let p):   try c.encode("displayInfo", forKey: .kind);    try c.encode(p, forKey: .data)
            case .mouseMove(let p):     try c.encode("mouseMove", forKey: .kind);      try c.encode(p, forKey: .data)
            case .mouseButton(let p):   try c.encode("mouseButton", forKey: .kind);    try c.encode(p, forKey: .data)
            case .mouseScroll(let p):   try c.encode("mouseScroll", forKey: .kind);    try c.encode(p, forKey: .data)
            case .keyEvent(let p):      try c.encode("keyEvent", forKey: .kind);       try c.encode(p, forKey: .data)
            case .textInput(let p):     try c.encode("textInput", forKey: .kind);      try c.encode(p, forKey: .data)
            case .qualityRequest(let p):try c.encode("qualityRequest", forKey: .kind); try c.encode(p, forKey: .data)
            case .error(let p):         try c.encode("error", forKey: .kind);          try c.encode(p, forKey: .data)
            case .ping(let p):          try c.encode("ping", forKey: .kind);           try c.encode(p, forKey: .data)
            case .pong(let p):          try c.encode("pong", forKey: .kind);           try c.encode(p, forKey: .data)
            }
        }
    }
}

// MARK: - Individual payload structs

public struct HelloPayload: Codable {
    public let appVersion: String
    public let platform: String     // "ios"
    public let deviceName: String
    public let supportedFeatures: [String]  // e.g. ["video", "input", "keyboard"]

    public init(appVersion: String = "1.0.0",
                platform: String = "ios",
                deviceName: String = "Device",
                supportedFeatures: [String] = ["video", "input", "keyboard"]) {
        self.appVersion = appVersion
        self.platform = platform
        self.deviceName = deviceName
        self.supportedFeatures = supportedFeatures
    }
}

public struct HelloAckPayload: Codable {
    public let hostAppVersion: String
    public let macOSVersion: String
    public let displayCount: Int
    public let requiresAuth: Bool
    public let serverTimestamp: Double

    public init(hostAppVersion: String,
                macOSVersion: String,
                displayCount: Int,
                requiresAuth: Bool) {
        self.hostAppVersion = hostAppVersion
        self.macOSVersion = macOSVersion
        self.displayCount = displayCount
        self.requiresAuth = requiresAuth
        self.serverTimestamp = Date().timeIntervalSince1970
    }
}

public struct AuthChallengePayload: Codable {
    public let challenge: String    // random hex token
    public init(challenge: String) { self.challenge = challenge }
}

public struct AuthResponsePayload: Codable {
    public let response: String     // HMAC-SHA256(sharedSecret, challenge) hex
    public init(response: String) { self.response = response }
}

public struct AuthResultPayload: Codable {
    public let success: Bool
    public let reason: String?
    public init(success: Bool, reason: String? = nil) {
        self.success = success; self.reason = reason
    }
}

public struct SessionInfoPayload: Codable {
    public let sessionID: String
    public let videoPort: Int           // UDP port for MJPEG/H.264 RTP
    public let controlPort: Int         // TCP port (already connected)
    public let displayWidth: Int
    public let displayHeight: Int
    public let displayScaleFactor: Double

    public init(sessionID: String,
                videoPort: Int,
                controlPort: Int,
                displayWidth: Int,
                displayHeight: Int,
                displayScaleFactor: Double) {
        self.sessionID = sessionID
        self.videoPort = videoPort
        self.controlPort = controlPort
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayScaleFactor = displayScaleFactor
    }
}

public struct DisplayInfoPayload: Codable {
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let displayIndex: Int
    public init(width: Int, height: Int, scaleFactor: Double, displayIndex: Int) {
        self.width = width; self.height = height
        self.scaleFactor = scaleFactor; self.displayIndex = displayIndex
    }
}

// MARK: - Mouse

public struct MouseMovePayload: Codable {
    /// Normalised coordinates in [0,1] relative to the captured display.
    public let normX: Double
    public let normY: Double
    public init(normX: Double, normY: Double) {
        self.normX = normX; self.normY = normY
    }
}

public enum MouseButton: String, Codable {
    case left, right, middle
}

public struct MouseButtonPayload: Codable {
    public let button: MouseButton
    public let pressed: Bool
    public let normX: Double
    public let normY: Double
    public let clickCount: Int  // 1 = single, 2 = double
    public init(button: MouseButton, pressed: Bool,
                normX: Double, normY: Double, clickCount: Int = 1) {
        self.button = button; self.pressed = pressed
        self.normX = normX; self.normY = normY; self.clickCount = clickCount
    }
}

public struct MouseScrollPayload: Codable {
    public let deltaX: Double   // points per event (can be fractional)
    public let deltaY: Double
    public let normX: Double
    public let normY: Double
    public init(deltaX: Double, deltaY: Double, normX: Double, normY: Double) {
        self.deltaX = deltaX; self.deltaY = deltaY
        self.normX = normX; self.normY = normY
    }
}

// MARK: - Keyboard

public struct KeyEventPayload: Codable {
    public let keyCode: UInt16          // macOS virtual key code
    public let pressed: Bool
    public let modifiers: UInt32        // CGEventFlags raw value (masked)
    public let characters: String?      // optional hint for display
    public init(keyCode: UInt16, pressed: Bool, modifiers: UInt32 = 0, characters: String? = nil) {
        self.keyCode = keyCode; self.pressed = pressed
        self.modifiers = modifiers; self.characters = characters
    }
}

public struct TextInputPayload: Codable {
    public let text: String
    public init(text: String) { self.text = text }
}

// MARK: - Quality

public struct QualityRequestPayload: Codable {
    public let targetFPS: Int               // 1-60
    public let targetWidth: Int             // pixels
    public let targetHeight: Int
    public let bitrateKbps: Int?            // nil = auto
    public init(targetFPS: Int, targetWidth: Int, targetHeight: Int, bitrateKbps: Int? = nil) {
        self.targetFPS = targetFPS; self.targetWidth = targetWidth
        self.targetHeight = targetHeight; self.bitrateKbps = bitrateKbps
    }
}

// MARK: - Diagnostics

public struct PingPayload: Codable {
    public let sentAt: Double
    public init() { self.sentAt = Date().timeIntervalSince1970 }
}

public struct PongPayload: Codable {
    public let echoedAt: Double
    public let receivedAt: Double
    public init(receivedAt: Double) {
        self.receivedAt = receivedAt
        self.echoedAt = Date().timeIntervalSince1970
    }
}

public struct ErrorPayload: Codable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code; self.message = message
    }
}

// MARK: - Framing helpers

public enum FramingError: Error {
    case messageTooLarge(Int)
    case invalidLength
    case decodingFailed(Error)
    case encodingFailed(Error)
}

public struct MessageFramer {
    private static let maxFrameSize = 4 * 1024 * 1024  // 4 MB safety cap

    /// Encode a ControlMessage to a length-prefixed Data frame.
    public static func encode(_ message: ControlMessage) throws -> Data {
        let json: Data
        do { json = try JSONEncoder().encode(message) }
        catch { throw FramingError.encodingFailed(error) }

        guard json.count <= maxFrameSize else {
            throw FramingError.messageTooLarge(json.count)
        }
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Extract zero or more complete ControlMessages from a raw byte buffer.
    /// Consumed bytes are removed from `buffer`.
    public static func decode(from buffer: inout Data) throws -> [ControlMessage] {
        var messages: [ControlMessage] = []
        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self).bigEndian
            }
            guard length <= maxFrameSize else {
                throw FramingError.invalidLength
            }
            let total = Int(length) + 4
            guard buffer.count >= total else { break }
            let json = buffer[4..<total]
            do {
                let msg = try JSONDecoder().decode(ControlMessage.self, from: json)
                messages.append(msg)
            } catch {
                throw FramingError.decodingFailed(error)
            }
            buffer.removeSubrange(0..<total)
        }
        return messages
    }
}

// MARK: - Shared constants

public enum MacLinkConstants {
    public static let defaultControlPort: UInt16 = 55_100
    public static let defaultVideoPort: UInt16   = 55_101
    public static let protocolVersion            = "1.0"
    public static let appVersion                 = "1.0.0"
    public static let pingInterval: TimeInterval = 5.0
    public static let connectionTimeout: TimeInterval = 10.0
    public static let reconnectDelay: TimeInterval = 2.0
    public static let maxReconnectAttempts        = 5
}

// MARK: - macOS virtual key codes (subset — enough for full keyboard support)

public enum MacKeyCode: UInt16 {
    // Letters
    case a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7
    case c = 8, v = 9, b = 11, q = 12, w = 13, e = 14, r = 15
    case y = 16, t = 17, u = 32, i = 34, o = 31, p = 35, l = 37
    case j = 38, k = 40, n = 45, m = 46

    // Numbers
    case one = 18, two = 19, three = 20, four = 21, six = 22, five = 23
    case equal = 24, nine = 25, seven = 26, minus = 27, eight = 28, zero = 29

    // Special
    case `return` = 36
    case tab = 48
    case space = 49
    case delete = 51        // backspace
    case escape = 53
    case forwardDelete = 117
    case home = 115
    case end = 119
    case pageUp = 116
    case pageDown = 121

    // Arrows
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126

    // Function keys
    case f1 = 122, f2 = 120, f3 = 99, f4 = 118
    case f5 = 96, f6 = 97, f7 = 98, f8 = 100
    case f9 = 101, f10 = 109, f11 = 103, f12 = 111

    // Symbols
    case leftBracket = 33, rightBracket = 30
    case quote = 39, semicolon = 41, backslash = 42
    case comma = 43, period = 47, slash = 44, backtick = 50
}

// CGEventFlags masks for modifier keys (sent in KeyEventPayload.modifiers)
public enum ModifierFlag: UInt32 {
    case shift      = 0x0002_0000  // NX_SHIFTMASK
    case control    = 0x0004_0000  // NX_CONTROLMASK
    case option     = 0x0008_0000  // NX_ALTERNATEMASK
    case command    = 0x0010_0000  // NX_COMMANDMASK
    case capsLock   = 0x0001_0000
    case numPad     = 0x0020_0000
}
