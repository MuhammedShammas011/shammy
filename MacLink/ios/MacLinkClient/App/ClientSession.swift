// ClientSession.swift
// MacLink – iOS Client
// Manages connection lifecycle: TCP handshake, auth, video receive loop,
// and exposes published state for the UI.

import Foundation
import Combine
import UIKit
import Network
import CryptoKit

// MARK: - Client connection state

enum ClientState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case error(String)

    var displayString: String {
        switch self {
        case .disconnected:          return "Disconnected"
        case .connecting:            return "Connecting…"
        case .authenticating:        return "Authenticating…"
        case .connected:             return "Connected"
        case .reconnecting(let n):   return "Reconnecting… (attempt \(n))"
        case .error(let m):          return "Error: \(m)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - ClientSession

@MainActor
final class ClientSession: ObservableObject {

    static let shared = ClientSession()

    // MARK: Published
    @Published var state: ClientState = .disconnected
    @Published var hostAddress: String = ""
    @Published var controlPort: UInt16 = MacLinkConstants.defaultControlPort
    @Published var sharedSecret: String = ""
    @Published var displayInfo: DisplayInfoPayload = DisplayInfoPayload(width: 1280, height: 720,
                                                                          scaleFactor: 2.0,
                                                                          displayIndex: 0)
    @Published var latencyMs: Double = 0
    @Published var framesReceived: UInt64 = 0
    @Published var currentFPS: Double = 0

    // Video frame publisher (decoded UIImage)
    let framePublisher = PassthroughSubject<UIImage, Never>()

    // MARK: Private
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var reconnectAttempts = 0
    private var pingTimer: Timer?
    private var lastPingSentAt: Double = 0
    private var fpsTracker = FPSTracker()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadSavedSettings()
    }

    // MARK: - Public API

    func connect() {
        guard !hostAddress.isEmpty else {
            state = .error("Enter a host address first.")
            return
        }
        reconnectAttempts = 0
        startConnection()
    }

    func disconnect() {
        cancelConnection()
        state = .disconnected
    }

    // MARK: - Connection

    private func startConnection() {
        cancelConnection()
        state = .connecting

        var targetHost = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetPort = controlPort
        if let colonIndex = targetHost.firstIndex(of: ":") {
            let portStr = String(targetHost[targetHost.index(after: colonIndex)...])
            if let p = UInt16(portStr) {
                targetPort = p
            }
            targetHost = String(targetHost[..<colonIndex])
        }

        let host = NWEndpoint.Host(targetHost)
        let port = NWEndpoint.Port(integerLiteral: targetPort)
        let params = NWParameters.tcp
        connection = NWConnection(host: host, port: port, using: params)

        connection?.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor in
                self?.handleNetworkState(nwState)
            }
        }
        connection?.start(queue: DispatchQueue(label: "maclink.client"))
    }

    private func handleNetworkState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            state = .authenticating
            Task { await performHandshake() }
        case .failed(let error):
            scheduleReconnect(reason: error.localizedDescription)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func cancelConnection() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        readBuffer = Data()
    }

    // MARK: - Reconnect

    private func scheduleReconnect(reason: String) {
        reconnectAttempts += 1
        guard reconnectAttempts <= MacLinkConstants.maxReconnectAttempts else {
            state = .error("Could not reconnect after \(MacLinkConstants.maxReconnectAttempts) attempts. Last error: \(reason)")
            return
        }
        state = .reconnecting(attempt: reconnectAttempts)
        let delay = MacLinkConstants.reconnectDelay * Double(reconnectAttempts)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startConnection()
        }
    }

    // MARK: - Handshake

    private func performHandshake() async {
        guard let conn = connection else { return }

        // 1. Send HELLO
        let hello = ControlMessage(type: .hello,
                                    payload: .hello(HelloPayload(
                                      deviceName: UIDevice.current.name)))
        do {
            try await sendMessage(hello, on: conn)
        } catch {
            scheduleReconnect(reason: error.localizedDescription)
            return
        }

        // 2. Receive HELLO ACK
        guard let ackMsg = try? await receiveOne(from: conn),
              ackMsg.type == .helloAck else {
            scheduleReconnect(reason: "Unexpected message from host.")
            return
        }

        // 3. Receive AUTH CHALLENGE
        guard let challengeMsg = try? await receiveOne(from: conn),
              challengeMsg.type == .authChallenge,
              case .authChallenge(let challenge) = challengeMsg.payload else {
            scheduleReconnect(reason: "Auth challenge not received.")
            return
        }

        // 4. Send AUTH RESPONSE
        let response = hmac(secret: sharedSecret, message: challenge.challenge)
        let respMsg = ControlMessage(type: .authResponse,
                                      payload: .authResponse(AuthResponsePayload(response: response)))
        do { try await sendMessage(respMsg, on: conn) }
        catch { scheduleReconnect(reason: error.localizedDescription); return }

        // 5. Receive AUTH RESULT
        guard let resultMsg = try? await receiveOne(from: conn),
              resultMsg.type == .authResult,
              case .authResult(let result) = resultMsg.payload,
              result.success else {
            state = .error("Authentication failed. Check the shared secret.")
            cancelConnection()
            return
        }

        // 6. Receive SESSION INFO
        guard let sessionMsg = try? await receiveOne(from: conn),
              sessionMsg.type == .sessionStarted,
              case .sessionInfo(let info) = sessionMsg.payload else {
            scheduleReconnect(reason: "Session info not received.")
            return
        }

        displayInfo = DisplayInfoPayload(width: info.displayWidth,
                                          height: info.displayHeight,
                                          scaleFactor: info.displayScaleFactor,
                                          displayIndex: 0)
        reconnectAttempts = 0
        state = .connected
        saveSettings()

        // 7. Start continuous receive loop (control messages + video frames on same channel)
        startReceiving()
        startPingTimer()
    }

    // MARK: - Receive loop

    private func startReceiving() {
        receiveNext()
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                self.drainBuffer()
            }
            if let error {
                Task { @MainActor in self.scheduleReconnect(reason: error.localizedDescription) }
                return
            }
            if isComplete {
                Task { @MainActor in self.scheduleReconnect(reason: "Connection closed by host.") }
                return
            }
            self.receiveNext()
        }
    }

    private func drainBuffer() {
        // Video frame packets start with a type byte 0x01 (JPEG) or 0x02 (H264)
        // Control messages start with the JSON length prefix (4 bytes, first byte is never 0x01/0x02
        // because UInt32 big-endian of any small control message length will have 0x00 as first byte)
        while !readBuffer.isEmpty {
            let firstByte = readBuffer[0]
            if firstByte == 0x01 || firstByte == 0x02 {
                // Video frame packet: 1 type + 8 index + 4 length + data
                guard readBuffer.count >= 13 else { return }
                let payloadLength = Int(readBuffer[9...12].withUnsafeBytes {
                    $0.load(as: UInt32.self).bigEndian
                })
                let total = 13 + payloadLength
                guard readBuffer.count >= total else { return }
                let payload = readBuffer[13..<total]
                readBuffer.removeSubrange(0..<total)
                if firstByte == 0x01 {
                    handleJPEGFrame(payload)
                }
                // H.264 decoding handled by VideoDecoder (future milestone)
            } else {
                // Control message
                if let messages = try? MessageFramer.decode(from: &readBuffer) {
                    for msg in messages {
                        Task { @MainActor in self.handleControlMessage(msg) }
                    }
                } else {
                    // Malformed; discard
                    readBuffer.removeAll()
                    return
                }
                if readBuffer.isEmpty { return }
                // If no messages decoded and buffer unchanged, wait for more data
            }
        }
    }

    private func handleJPEGFrame(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        Task { @MainActor in
            self.framePublisher.send(image)
            self.framesReceived += 1
            self.currentFPS = self.fpsTracker.tick()
        }
    }

    private func handleControlMessage(_ msg: ControlMessage) {
        switch msg.type {
        case .displayInfo:
            if case .displayInfo(let info) = msg.payload {
                displayInfo = info
            }
        case .pong:
            if case .pong(let p) = msg.payload {
                latencyMs = (Date().timeIntervalSince1970 - p.receivedAt) * 1000
            }
        case .stopSession, .sessionStopped:
            cancelConnection()
            state = .disconnected
        case .error:
            if case .error(let e) = msg.payload {
                state = .error(e.message)
            }
        default: break
        }
    }

    // MARK: - Ping timer

    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: MacLinkConstants.pingInterval,
                                          repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let ping = ControlMessage(type: .ping, payload: .ping(PingPayload()))
                try? await self.sendMessage(ping, on: self.connection!)
            }
        }
    }

    // MARK: - Send control message

    func send(_ message: ControlMessage) {
        guard let conn = connection else { return }
        Task { try? await sendMessage(message, on: conn) }
    }

    private func sendMessage(_ message: ControlMessage, on conn: NWConnection) async throws {
        let data = try MessageFramer.encode(message)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    private func receiveOne(from conn: NWConnection) async throws -> ControlMessage {
        try await withCheckedThrowingContinuation { continuation in
            var buf = Data()
            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let data { buf.append(data) }
                    if let msgs = try? MessageFramer.decode(from: &buf), let first = msgs.first {
                        continuation.resume(returning: first)
                    } else if isComplete {
                        continuation.resume(throwing: URLError(.networkConnectionLost))
                    } else {
                        recv()
                    }
                }
            }
            recv()
        }
    }

    // MARK: - HMAC

    private func hmac(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Settings persistence

    private func loadSavedSettings() {
        hostAddress  = UserDefaults.standard.string(forKey: "maclink.host")   ?? ""
        sharedSecret = UserDefaults.standard.string(forKey: "maclink.secret") ?? ""
        controlPort  = UInt16(UserDefaults.standard.integer(forKey: "maclink.port").nonZero
                              ?? Int(MacLinkConstants.defaultControlPort))
    }

    private func saveSettings() {
        UserDefaults.standard.set(hostAddress,  forKey: "maclink.host")
        UserDefaults.standard.set(sharedSecret, forKey: "maclink.secret")
        UserDefaults.standard.set(Int(controlPort), forKey: "maclink.port")
    }
}

// MARK: - FPS tracker

private struct FPSTracker {
    private var timestamps: [CFAbsoluteTime] = []

    mutating func tick() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        timestamps.append(now)
        // Keep only last-second timestamps
        timestamps = timestamps.filter { now - $0 < 1.0 }
        return Double(timestamps.count)
    }
}

// MARK: - Int helper

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
