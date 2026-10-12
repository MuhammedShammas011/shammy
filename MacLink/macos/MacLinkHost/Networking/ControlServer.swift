// ControlServer.swift
// MacLink – macOS Host
// TCP server that listens on a configurable port, accepts one client connection,
// performs the handshake/authentication sequence, then publishes incoming
// ControlMessages and allows sending outgoing ones.

import Foundation
import Network
import Combine
import CryptoKit
import AppKit
import CoreGraphics

// MARK: - Server connection state (internal)

enum ServerConnectionState {
    case idle
    case listening
    case connected
    case disconnected
}

// MARK: - ControlServer

final class ControlServer {

    let messagePublisher = PassthroughSubject<ControlMessage, Never>()
    let statePublisher   = PassthroughSubject<ServerConnectionState, Never>()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var sharedSecret: String = ""   // set from preferences or random on first run

    // Video streamer reference so we can hand it the connection
    var videoStreamer: VideoStreamer?

    // MARK: - Start / Stop

    func start(port: UInt16) async throws {
        sharedSecret = loadOrGenerateSecret()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false  // allow Tailscale connections

        let nwPort = NWEndpoint.Port(integerLiteral: port)
        listener = try NWListener(using: params, on: nwPort)
        listener?.stateUpdateHandler = { state in
            print("[Server] Listener state: \(state)")
        }
        listener?.start(queue: DispatchQueue(label: "maclink.server"))
    }

    func waitForClient() async throws -> String {
        guard let listener else { throw ServerError.notStarted }

        return try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.listener?.newConnectionHandler = nil   // accept only one
                self.connection = conn
                Task {
                    do {
                        let name = try await self.performHandshake(on: conn)
                        continuation.resume(returning: name)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        statePublisher.send(.disconnected)
    }

    // MARK: - Send

    func send(_ message: ControlMessage) async throws {
        guard let conn = connection else { throw ServerError.noConnection }
        let data = try MessageFramer.encode(message)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    // MARK: - Handshake

    private func performHandshake(on conn: NWConnection) async throws -> String {
        conn.start(queue: DispatchQueue(label: "maclink.conn"))
        videoStreamer?.connection = conn

        // Wait for HELLO
        let helloMsg = try await receiveOne(from: conn)
        guard helloMsg.type == .hello,
              case .hello(let hello) = helloMsg.payload else {
            throw ServerError.unexpectedMessage
        }

        // Send HELLO ACK
        let ack = ControlMessage(type: .helloAck,
                                  payload: .helloAck(HelloAckPayload(
                                    hostAppVersion: MacLinkConstants.appVersion,
                                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                    displayCount: NSScreen.screens.count,
                                    requiresAuth: true)))
        let ackData = try MessageFramer.encode(ack)
        try await sendRaw(ackData, on: conn)

        // Issue auth challenge
        let challenge = randomHex(32)
        let challengeMsg = ControlMessage(type: .authChallenge,
                                           payload: .authChallenge(AuthChallengePayload(challenge: challenge)))
        try await sendRaw(try MessageFramer.encode(challengeMsg), on: conn)

        // Receive auth response
        let responseMsg = try await receiveOne(from: conn)
        guard responseMsg.type == .authResponse,
              case .authResponse(let resp) = responseMsg.payload else {
            throw ServerError.authFailed
        }

        // Verify HMAC
        let expected = hmac(secret: sharedSecret, message: challenge)
        let authOK = resp.response == expected

        let resultMsg = ControlMessage(type: .authResult,
                                        payload: .authResult(AuthResultPayload(
                                          success: authOK,
                                          reason: authOK ? nil : "Invalid auth token")))
        try await sendRaw(try MessageFramer.encode(resultMsg), on: conn)

        guard authOK else { throw ServerError.authFailed }

        // Send session info
        let sessionID = UUID().uuidString
        let displayWidth  = CGDisplayPixelsWide(CGMainDisplayID())
        let displayHeight = CGDisplayPixelsHigh(CGMainDisplayID())
        let sessionMsg = ControlMessage(type: .sessionStarted,
                                         payload: .sessionInfo(SessionInfoPayload(
                                           sessionID: sessionID,
                                           videoPort: 0,          // video on same TCP conn
                                           controlPort: 0,
                                           displayWidth: displayWidth,
                                           displayHeight: displayHeight,
                                           displayScaleFactor: Double(NSScreen.main?.backingScaleFactor ?? 2.0))))
        try await sendRaw(try MessageFramer.encode(sessionMsg), on: conn)

        // Start the continuous read loop
        startReceiving(from: conn)
        statePublisher.send(.connected)

        return hello.deviceName
    }

    // MARK: - Continuous receive

    private func startReceiving(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                if let messages = try? MessageFramer.decode(from: &self.readBuffer) {
                    for msg in messages {
                        self.messagePublisher.send(msg)
                    }
                }
            }
            if let error {
                print("[Server] Receive error: \(error)")
                self.statePublisher.send(.disconnected)
                return
            }
            if isComplete {
                self.statePublisher.send(.disconnected)
                return
            }
            self.startReceiving(from: conn)
        }
    }

    // MARK: - Helpers

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
                        continuation.resume(throwing: ServerError.connectionClosed)
                    } else {
                        recv()
                    }
                }
            }
            recv()
        }
    }

    private func sendRaw(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    // MARK: - Auth helpers

    private func hmac(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrGenerateSecret() -> String {
        let key = "maclink.shared_secret"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let secret = randomHex(32)
        UserDefaults.standard.set(secret, forKey: key)
        return secret
    }
}

// MARK: - Errors

enum ServerError: LocalizedError {
    case notStarted
    case noConnection
    case unexpectedMessage
    case authFailed
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .notStarted:          return "Server not started."
        case .noConnection:        return "No client connected."
        case .unexpectedMessage:   return "Unexpected message from client."
        case .authFailed:          return "Authentication failed."
        case .connectionClosed:    return "Connection closed by client."
        }
    }
}
