// SessionManager.swift
// MacLink – macOS Host
// Central coordinator: ties together ScreenCaptureManager, VideoStreamer,
// ControlServer, and InputInjector.

import Foundation
import Combine
import AppKit
import Network

// MARK: - Session state

enum SessionState: Equatable {
    case idle
    case listening          // TCP server is up, waiting for client
    case handshaking        // client connected, doing auth
    case connected          // fully authenticated, streaming
    case error(String)

    var displayString: String {
        switch self {
        case .idle:         return "Idle"
        case .listening:    return "Listening for connection…"
        case .handshaking:  return "Authenticating…"
        case .connected:    return "Connected"
        case .error(let m): return "Error: \(m)"
        }
    }
}

// MARK: - SessionManager

@MainActor
final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    // MARK: Published state
    @Published var state: SessionState = .idle
    @Published var connectedDeviceName: String = ""
    @Published var localIP: String = ""
    @Published var tailscaleIP: String = ""
    @Published var controlPort: UInt16 = 55_101
    @Published var webPort: UInt16     = 55_100
    @Published var videoPort: UInt16   = MacLinkConstants.defaultVideoPort
    @Published var screenCaptureAuthorized: Bool = false
    @Published var accessibilityAuthorized: Bool = false
    @Published var framesPerSecond: Double = 0
    @Published var lastError: String = ""

    var connectionAddress: String {
        let ip = tailscaleIP.isEmpty ? localIP : tailscaleIP
        return ip.isEmpty ? "" : "\(ip):\(controlPort)"
    }

    var webURLString: String {
        let ip = tailscaleIP.isEmpty ? localIP : tailscaleIP
        return ip.isEmpty ? "" : "http://\(ip):\(webPort)"
    }

    // MARK: Sub-systems
    private let capture   = ScreenCaptureManager()
    private let streamer  = VideoStreamer()
    private let server    = ControlServer()
    private let input     = InputInjector()
    private let webServer = WebRemoteServer()

    private var cancellables = Set<AnyCancellable>()

    // MARK: Init
    private init() {
        setupObservers()
        updateNetworkAddresses()
        checkPermissions()
        startWebServer()
    }

    // MARK: - Public API

    func startSession() {
        guard state == .idle || {
            if case .error = state { return true }
            return false
        }() else { return }

        lastError = ""
        state = .listening

        Task {
            await startInternal()
        }
    }

    func stopSession() {
        server.stop()
        capture.stop()
        streamer.stop()
        state = .idle
        connectedDeviceName = ""
        framesPerSecond = 0
    }

    func checkPermissions() {
        screenCaptureAuthorized = PermissionChecker.hasScreenRecordingPermission()
        accessibilityAuthorized = PermissionChecker.hasAccessibilityPermission()
    }

    func requestScreenRecordingPermission() {
        PermissionChecker.requestScreenRecordingPermission()
    }

    func requestAccessibilityPermission() {
        PermissionChecker.requestAccessibilityPermission()
    }

    // MARK: - Web Remote Server

    func startWebServer() {
        webServer.inputInjector = input
        webServer.getDisplayInfo = { [weak self] in
            self?.capture.currentDisplayInfo ?? DisplayInfo(width: 1920, height: 1080, scaleFactor: 2.0, displayID: 0)
        }
        webServer.isCapturing = { [weak self] in
            self?.capture.isCapturing ?? false
        }
        webServer.onNeedCapture = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.ensureCaptureRunning()
            }
        }
        webServer.onUpdateSettings = { [weak self] fps, quality in
            self?.capture.updateSettings(fps: fps, width: 1280, height: 800)
            self?.streamer.jpegQuality = quality
        }

        // Pipe frames from capture to streamer
        capture.framePublisher
            .sink { [weak self] frame in
                self?.streamer.enqueue(frame)
            }
            .store(in: &cancellables)

        capture.fpsPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$framesPerSecond)

        do {
            try webServer.start(port: webPort, jpegPublisher: streamer.onJPEGFrame.eraseToAnyPublisher())
            print("[SessionManager] Web remote server running on port \(webPort)")
            Task { @MainActor [weak self] in
                await self?.ensureCaptureRunning()
            }
        } catch {
            print("[SessionManager] Failed to start web remote server: \(error)")
        }
    }

    func ensureCaptureRunning() async {
        guard !capture.isCapturing else { return }
        do {
            try await capture.start()
            state = .connected
            screenCaptureAuthorized = true
            connectedDeviceName = "Mobile Web Client"
            lastError = ""
            print("[SessionManager] Screen capture started successfully!")
        } catch {
            print("[SessionManager] Error starting capture: \(error)")
            lastError = "Screen capture: \(error.localizedDescription)"
            checkPermissions()
            if !screenCaptureAuthorized {
                PermissionChecker.requestScreenRecordingPermission()
            }
        }
    }

    // MARK: - Internal startup

    private func startInternal() async {
        updateNetworkAddresses()

        // 1. Verify permissions
        screenCaptureAuthorized = PermissionChecker.hasScreenRecordingPermission()
        accessibilityAuthorized = PermissionChecker.hasAccessibilityPermission()

        guard screenCaptureAuthorized else {
            state = .error("Screen recording permission required. Grant it in System Settings → Privacy & Security → Screen Recording.")
            return
        }

        // 2. Start control TCP server
        do {
            try await server.start(port: controlPort)
        } catch {
            state = .error("Failed to start control server: \(error.localizedDescription)")
            return
        }

        // 3. Wait for a client connection
        do {
            let clientName = try await server.waitForClient()
            connectedDeviceName = clientName
        } catch {
            state = .error("Connection failed: \(error.localizedDescription)")
            return
        }

        state = .connected

        // 4. Start screen capture
        do {
            try await capture.start()
        } catch {
            stopSession()
            state = .error("Screen capture failed: \(error.localizedDescription)")
            return
        }

        // 5. Pipe frames → video streamer → client
        capture.framePublisher
            .sink { [weak self] frame in
                self?.streamer.enqueue(frame)
            }
            .store(in: &cancellables)

        capture.fpsPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$framesPerSecond)

        // 6. Route incoming control messages to input injector
        server.messagePublisher
            .sink { [weak self] message in
                self?.handleControlMessage(message)
            }
            .store(in: &cancellables)

        // 7. Send display info to client
        let info = capture.currentDisplayInfo
        let msg = ControlMessage(type: .displayInfo,
                                  payload: .displayInfo(DisplayInfoPayload(
                                    width: info.width,
                                    height: info.height,
                                    scaleFactor: info.scaleFactor,
                                    displayIndex: 0)))
        try? await server.send(msg)
    }

    // MARK: - Message routing

    private func handleControlMessage(_ msg: ControlMessage) {
        switch msg.type {
        case .mouseMove:
            if case .mouseMove(let p) = msg.payload {
                input.injectMouseMove(normX: p.normX, normY: p.normY,
                                       display: capture.currentDisplayInfo)
            }
        case .mouseDown, .mouseUp:
            if case .mouseButton(let p) = msg.payload {
                input.injectMouseButton(p, display: capture.currentDisplayInfo)
            }
        case .mouseScroll:
            if case .mouseScroll(let p) = msg.payload {
                input.injectScroll(p)
            }
        case .keyDown, .keyUp:
            if case .keyEvent(let p) = msg.payload {
                input.injectKey(p)
            }
        case .textInput:
            if case .textInput(let p) = msg.payload {
                input.injectText(p.text)
            }
        case .qualityRequest:
            if case .qualityRequest(let p) = msg.payload {
                capture.updateSettings(fps: p.targetFPS,
                                        width: p.targetWidth,
                                        height: p.targetHeight)
            }
        case .ping:
            if case .ping(let p) = msg.payload {
                let pong = ControlMessage(type: .pong,
                                           payload: .pong(PongPayload(receivedAt: p.sentAt)))
                Task { try? await server.send(pong) }
            }
        case .stopSession:
            DispatchQueue.main.async { self.stopSession() }
        default:
            break
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        server.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] serverState in
                switch serverState {
                case .disconnected:
                    if self?.state == .connected {
                        self?.state = .idle
                        self?.connectedDeviceName = ""
                        self?.capture.stop()
                    }
                default: break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Network address discovery

    func updateNetworkAddresses() {
        localIP = NetworkUtils.localIPAddress() ?? ""
        tailscaleIP = NetworkUtils.tailscaleIPAddress() ?? ""
    }
}
