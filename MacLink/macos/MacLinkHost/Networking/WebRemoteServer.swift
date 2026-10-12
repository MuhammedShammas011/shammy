// WebRemoteServer.swift
// Shammy – macOS Host
// Embedded HTTP & MJPEG web server that allows any mobile browser (Chrome, Safari)
// to view and control the Mac desktop with zero app install required.

import Foundation
import Network
import Combine
import CoreGraphics
import AppKit
import CryptoKit

final class WebRemoteServer {

    private var listener: NWListener?
    private var streamConnections = [ObjectIdentifier: NWConnection]()
    private let streamQueue = DispatchQueue(label: "shammy.webstream", qos: .userInteractive)
    private var cancellables = Set<AnyCancellable>()

    private var isSendingFrame = [ObjectIdentifier: Bool]()
    private var pendingFrame = [ObjectIdentifier: Data]()

    var onNeedCapture: (() async -> Void)?
    var getDisplayInfo: (() -> DisplayInfo)?
    var inputInjector: InputInjector?
    var isCapturing: (() -> Bool)?
    var onUpdateSettings: ((Int, CGFloat) -> Void)?
    var onStartSession: (() -> Void)?
    var onStopSession: (() -> Void)?
    var getSessionState: (() -> String)?
    var getLastError: (() -> String)?

    private lazy var placeholderJPEGData: Data = {
        let size = NSSize(width: 1280, height: 720)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1.0).drawSwatch(in: NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "Connecting to Mac Screen...", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return Data()
        }
        return data
    }()

    private lazy var appIconPNGData: Data? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let fallback = URL(fileURLWithPath: "/Users/shammas/Downloads/Jacky/MacLink/macos/MacLinkHost/Resources/AppIcon.png")
        return try? Data(contentsOf: fallback)
    }()

    func start(port: UInt16, jpegPublisher: AnyPublisher<Data, Never>) throws {
        stop()

        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false
        params.includePeerToPeer = true
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[WebRemoteServer] Listening on port \(port)")
            case .failed(let err):
                print("[WebRemoteServer] Listener failed: \(err)")
            default:
                break
            }
        }

        listener.start(queue: DispatchQueue(label: "shammy.weblistener"))

        // Subscribe to incoming JPEG frames
        jpegPublisher
            .receive(on: streamQueue)
            .sink { [weak self] jpegData in
                self?.broadcastFrame(jpegData)
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        listener?.cancel()
        listener = nil

        streamQueue.sync {
            for (_, conn) in streamConnections {
                conn.cancel()
            }
            streamConnections.removeAll()
            isSendingFrame.removeAll()
            pendingFrame.removeAll()
        }
    }

    // MARK: - Handle Connection

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "shammy.httpclient"))
        readHTTP(conn: conn)
    }

    private func readHTTP(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                conn.cancel()
                return
            }
            guard let data = content, !data.isEmpty else {
                if isComplete { conn.cancel() }
                return
            }

            self.processHTTPRequest(data: data, conn: conn)
        }
    }

    private func processHTTPRequest(data: Data, conn: NWConnection) {
        guard let requestStr = String(data: data, encoding: .utf8) else {
            conn.cancel()
            return
        }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            conn.cancel()
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            conn.cancel()
            return
        }

        let method = parts[0].uppercased()
        let fullPath = parts[1]
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        // Check for WebSocket Upgrade
        if let upgrade = lines.first(where: { $0.lowercased().hasPrefix("upgrade:") }),
           upgrade.lowercased().contains("websocket"),
           let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) {
            let key = keyLine.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            handleWebSocketUpgrade(key: key, conn: conn)
            return
        }

        if method == "OPTIONS" {
            let resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
            sendData(resp.data(using: .utf8)!, on: conn, close: true)
            return
        }

        switch path {
        case "/", "/index.html":
            let htmlData = webClientHTML.data(using: .utf8)!
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(htmlData.count)\r\nConnection: close\r\n\r\n"
            var body = header.data(using: .utf8)!
            body.append(htmlData)
            sendData(body, on: conn, close: true)

        case "/stream":
            // Trigger capture
            Task { [weak self] in
                await self?.onNeedCapture?()
            }

            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            var initialPacket = header.data(using: .utf8)!
            let placeholder = self.placeholderJPEGData
            initialPacket.append(contentsOf: "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(placeholder.count)\r\n\r\n".utf8)
            initialPacket.append(placeholder)
            initialPacket.append(contentsOf: "\r\n".utf8)

            conn.send(content: initialPacket, completion: .contentProcessed { [weak self] err in
                guard let self = self, err == nil else {
                    conn.cancel()
                    return
                }
                self.streamQueue.async {
                    let id = ObjectIdentifier(conn)
                    self.streamConnections[id] = conn
                }
            })

            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.streamQueue.async {
                        let id = ObjectIdentifier(conn)
                        self?.streamConnections.removeValue(forKey: id)
                        self?.isSendingFrame.removeValue(forKey: id)
                        self?.pendingFrame.removeValue(forKey: id)
                    }
                default: break
                }
            }

        case "/api/mouse":
            handleMouseAPI(data: data, conn: conn)

        case "/api/keyboard":
            handleKeyboardAPI(data: data, conn: conn)

        case "/api/settings":
            handleSettingsAPI(data: data, conn: conn)

        case "/api/session/start":
            onStartSession?()
            let respStart = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"
            sendData(respStart.data(using: .utf8)!, on: conn, close: true)

        case "/api/session/stop":
            onStopSession?()
            let respStop = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"
            sendData(respStop.data(using: .utf8)!, on: conn, close: true)

        case "/api/status":
            let info = getDisplayInfo?() ?? DisplayInfo(width: 1920, height: 1080, scaleFactor: 2.0, displayID: 0)
            let screenPerm = PermissionChecker.hasScreenRecordingPermission()
            let axPerm = PermissionChecker.hasAccessibilityPermission()
            let capturing = isCapturing?() ?? false
            let granted = screenPerm || capturing
            let sessState = getSessionState?() ?? "Idle"
            let err = getLastError?() ?? ""
            let json = "{\"status\":\"ok\",\"width\":\(info.width),\"height\":\(info.height),\"screenRecordingGranted\":\(granted),\"accessibilityGranted\":\(axPerm),\"isCapturing\":\(capturing),\"sessionState\":\"\(sessState)\",\"lastError\":\"\(err)\"}"
            let jsonBytes = json.data(using: .utf8)!
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(jsonBytes.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var resp = header.data(using: .utf8)!
            resp.append(jsonBytes)
            sendData(resp, on: conn, close: true)

        case "/icon.png", "/favicon.ico", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png":
            if let iconData = self.appIconPNGData {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(iconData.count)\r\nCache-Control: public, max-age=86400\r\nConnection: close\r\n\r\n"
                var resp = header.data(using: .utf8)!
                resp.append(iconData)
                sendData(resp, on: conn, close: true)
            } else {
                let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                sendData(resp.data(using: .utf8)!, on: conn, close: true)
            }

        default:
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendData(notFound.data(using: .utf8)!, on: conn, close: true)
        }
    }

    // MARK: - Broadcast MJPEG frame (Non-blocking, drops stale frames to prevent bufferbloat)

    private func broadcastFrame(_ jpegData: Data) {
        guard !streamConnections.isEmpty else { return }

        var packet = Data()
        packet.append(contentsOf: "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n".utf8)
        packet.append(jpegData)
        packet.append(contentsOf: "\r\n".utf8)

        for (id, conn) in streamConnections {
            if isSendingFrame[id] == true {
                // Network transmission in flight. Buffer only the freshest frame, dropping intermediate ones.
                pendingFrame[id] = packet
                continue
            }
            sendFramePacket(packet, to: conn, id: id)
        }
    }

    private func sendFramePacket(_ packet: Data, to conn: NWConnection, id: ObjectIdentifier) {
        isSendingFrame[id] = true
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            self.streamQueue.async {
                if err != nil {
                    self.streamConnections.removeValue(forKey: id)
                    self.isSendingFrame.removeValue(forKey: id)
                    self.pendingFrame.removeValue(forKey: id)
                    conn.cancel()
                    return
                }

                if let nextPacket = self.pendingFrame.removeValue(forKey: id) {
                    self.sendFramePacket(nextPacket, to: conn, id: id)
                } else {
                    self.isSendingFrame[id] = false
                }
            }
        })
    }

    // MARK: - WebSocket Handling

    private func handleWebSocketUpgrade(key: String, conn: NWConnection) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = Insecure.SHA1.hash(data: Data(combined.utf8))
        let acceptKey = Data(hash).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        conn.send(content: resp.data(using: .utf8)!, completion: .contentProcessed { [weak self] err in
            guard let self = self, err == nil else {
                conn.cancel()
                return
            }
            self.startWebSocketLoop(conn: conn)
        })
    }

    private func startWebSocketLoop(conn: NWConnection) {
        var buffer = Data()
        func readNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
                guard let self = self else { return }
                if err != nil {
                    conn.cancel()
                    return
                }
                if let data = data, !data.isEmpty {
                    buffer.append(data)
                    self.processWebSocketFrames(&buffer, conn: conn)
                }
                if isComplete {
                    conn.cancel()
                    return
                }
                readNext()
            }
        }
        readNext()
    }

    private func processWebSocketFrames(_ buffer: inout Data, conn: NWConnection) {
        while buffer.count >= 2 {
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let opcode = b0 & 0x0F
            let isMasked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var headerLen = 2

            if payloadLen == 126 {
                guard buffer.count >= 4 else { return }
                let high = Int(buffer[buffer.startIndex + 2])
                let low = Int(buffer[buffer.startIndex + 3])
                payloadLen = (high << 8) | low
                headerLen = 4
            } else if payloadLen == 127 {
                guard buffer.count >= 10 else { return }
                var len: UInt64 = 0
                for i in 0..<8 {
                    len = (len << 8) | UInt64(buffer[buffer.startIndex + 2 + i])
                }
                payloadLen = Int(len)
                headerLen = 10
            }

            let maskLen = isMasked ? 4 : 0
            let totalFrameLen = headerLen + maskLen + payloadLen
            guard buffer.count >= totalFrameLen else { return }

            var maskKey = [UInt8](repeating: 0, count: 4)
            if isMasked {
                let maskStart = buffer.startIndex + headerLen
                for i in 0..<4 {
                    maskKey[i] = buffer[maskStart + i]
                }
            }

            let payloadStart = buffer.startIndex + headerLen + maskLen
            let rawPayload = buffer.subdata(in: payloadStart..<(payloadStart + payloadLen))
            var unmasked = Data(count: payloadLen)
            if isMasked {
                for i in 0..<payloadLen {
                    unmasked[i] = rawPayload[rawPayload.startIndex + i] ^ maskKey[i % 4]
                }
            } else {
                unmasked = rawPayload
            }

            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + totalFrameLen))

            if opcode == 0x8 { // Close
                conn.cancel()
                return
            } else if opcode == 0x9 { // Ping -> Pong
                let pong = Data([0x8A, 0x00])
                conn.send(content: pong, completion: .contentProcessed { _ in })
            } else if opcode == 0x1 { // Text frame
                if let dict = try? JSONSerialization.jsonObject(with: unmasked) as? [String: Any] {
                    self.handleInputDict(dict)
                }
            }
        }
    }

    // MARK: - Input Message Processing (Shared for WebSocket & HTTP)

    private func handleInputDict(_ dict: [String: Any]) {
        guard let action = dict["action"] as? String else { return }
        let display = getDisplayInfo?() ?? DisplayInfo(width: 1920, height: 1080, scaleFactor: 2.0, displayID: 0)
        let normX = dict["normX"] as? Double ?? -1.0
        let normY = dict["normY"] as? Double ?? -1.0

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let input = self.inputInjector else { return }
            switch action {
            case "delta":
                let dx = dict["dx"] as? Double ?? 0.0
                let dy = dict["dy"] as? Double ?? 0.0
                input.injectMouseDelta(dx: dx, dy: dy, display: display)

            case "move":
                let nx = normX >= 0 ? normX : 0.5
                let ny = normY >= 0 ? normY : 0.5
                input.injectMouseMove(normX: nx, normY: ny, display: display)

            case "click":
                let btnStr = dict["button"] as? String ?? "left"
                let btn: MouseButton = (btnStr == "right") ? .right : .left
                input.injectMouseButton(MouseButtonPayload(button: btn, pressed: true, normX: normX, normY: normY, clickCount: 1), display: display)
                input.injectMouseButton(MouseButtonPayload(button: btn, pressed: false, normX: normX, normY: normY, clickCount: 1), display: display)

            case "button":
                let btnStr = dict["button"] as? String ?? "left"
                let btn: MouseButton = (btnStr == "right") ? .right : .left
                let pressed = dict["pressed"] as? Bool ?? true
                input.injectMouseButton(MouseButtonPayload(button: btn, pressed: pressed, normX: normX, normY: normY, clickCount: 1), display: display)

            case "doubleClick":
                input.injectMouseButton(MouseButtonPayload(button: .left, pressed: true, normX: normX, normY: normY, clickCount: 1), display: display)
                input.injectMouseButton(MouseButtonPayload(button: .left, pressed: false, normX: normX, normY: normY, clickCount: 1), display: display)
                input.injectMouseButton(MouseButtonPayload(button: .left, pressed: true, normX: normX, normY: normY, clickCount: 2), display: display)
                input.injectMouseButton(MouseButtonPayload(button: .left, pressed: false, normX: normX, normY: normY, clickCount: 2), display: display)

            case "scroll":
                let dx = dict["deltaX"] as? Double ?? 0.0
                let dy = dict["deltaY"] as? Double ?? 0.0
                let nx = normX >= 0 ? normX : 0.5
                let ny = normY >= 0 ? normY : 0.5
                input.injectScroll(MouseScrollPayload(deltaX: dx, deltaY: dy, normX: nx, normY: ny))

            case "text":
                if let text = dict["text"] as? String {
                    input.injectText(text)
                }

            case "key":
                if let keyCode = dict["keyCode"] as? UInt16 {
                    let pressed = dict["pressed"] as? Bool ?? true
                    let mods = dict["modifiers"] as? UInt32 ?? 0
                    input.injectKey(KeyEventPayload(keyCode: keyCode, pressed: pressed, modifiers: mods))
                }

            case "shortcut":
                if let name = dict["name"] as? String {
                    self.handleShortcut(name: name, input: input)
                }

            case "settings":
                let fps = dict["fps"] as? Int ?? 30
                let quality = dict["quality"] as? Double ?? 0.5
                self.onUpdateSettings?(fps, CGFloat(quality))

            default:
                break
            }
        }
    }

    // MARK: - Settings API

    private func handleSettingsAPI(data: Data, conn: NWConnection) {
        guard let body = extractJSONBody(data: data),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONError(conn: conn)
            return
        }

        let fps = dict["fps"] as? Int ?? 30
        let quality = dict["quality"] as? Double ?? 0.5
        DispatchQueue.main.async { [weak self] in
            self?.onUpdateSettings?(fps, CGFloat(quality))
        }
        sendJSONOK(conn: conn)
    }

    // MARK: - Mouse API

    private func handleMouseAPI(data: Data, conn: NWConnection) {
        guard let body = extractJSONBody(data: data),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONError(conn: conn)
            return
        }

        handleInputDict(dict)
        sendJSONOK(conn: conn)
    }

    // MARK: - Keyboard API

    private func handleKeyboardAPI(data: Data, conn: NWConnection) {
        guard let body = extractJSONBody(data: data),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONError(conn: conn)
            return
        }

        handleInputDict(dict)
        sendJSONOK(conn: conn)
    }

    private func handleShortcut(name: String, input: InputInjector) {
        // macOS virtual key codes:
        // Space: 0x31 (49), Tab: 0x30 (48), Return: 0x24 (36), Delete: 0x33 (51), Esc: 0x35 (53)
        // C: 0x08 (8), V: 0x09 (9), Z: 0x06 (6), W: 0x0D (13), A: 0x00 (0)
        // Up: 0x7E (126), Down: 0x7D (125), Left: 0x7B (123), Right: 0x7C (124)
        let cmdFlag: UInt32 = 0x00100000

        switch name {
        case "spotlight":
            input.injectKey(KeyEventPayload(keyCode: 49, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 49, pressed: false, modifiers: 0))

        case "appSwitcher":
            input.injectKey(KeyEventPayload(keyCode: 48, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 48, pressed: false, modifiers: 0))

        case "copy":
            input.injectKey(KeyEventPayload(keyCode: 8, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 8, pressed: false, modifiers: 0))

        case "paste":
            input.injectKey(KeyEventPayload(keyCode: 9, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 9, pressed: false, modifiers: 0))

        case "undo":
            input.injectKey(KeyEventPayload(keyCode: 6, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 6, pressed: false, modifiers: 0))

        case "close":
            input.injectKey(KeyEventPayload(keyCode: 13, pressed: true, modifiers: cmdFlag))
            input.injectKey(KeyEventPayload(keyCode: 13, pressed: false, modifiers: 0))

        case "enter":
            input.injectKey(KeyEventPayload(keyCode: 36, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 36, pressed: false, modifiers: 0))

        case "backspace":
            input.injectKey(KeyEventPayload(keyCode: 51, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 51, pressed: false, modifiers: 0))

        case "escape":
            input.injectKey(KeyEventPayload(keyCode: 53, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 53, pressed: false, modifiers: 0))

        case "tab":
            input.injectKey(KeyEventPayload(keyCode: 48, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 48, pressed: false, modifiers: 0))

        case "arrowUp":
            input.injectKey(KeyEventPayload(keyCode: 126, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 126, pressed: false, modifiers: 0))

        case "arrowDown":
            input.injectKey(KeyEventPayload(keyCode: 125, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 125, pressed: false, modifiers: 0))

        case "arrowLeft":
            input.injectKey(KeyEventPayload(keyCode: 123, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 123, pressed: false, modifiers: 0))

        case "arrowRight":
            input.injectKey(KeyEventPayload(keyCode: 124, pressed: true, modifiers: 0))
            input.injectKey(KeyEventPayload(keyCode: 124, pressed: false, modifiers: 0))

        default:
            break
        }
    }

    // MARK: - Helpers

    private func extractJSONBody(data: Data) -> Data? {
        guard let marker = "\r\n\r\n".data(using: .utf8),
              let range = data.range(of: marker) else { return nil }
        return data.subdata(in: range.upperBound..<data.count)
    }

    private func sendJSONOK(conn: NWConnection) {
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"ok\":true}"
        sendData(resp.data(using: .utf8)!, on: conn, close: true)
    }

    private func sendJSONError(conn: NWConnection) {
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 17\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"error\":\"bad\"}"
        sendData(resp.data(using: .utf8)!, on: conn, close: true)
    }

    private func sendData(_ data: Data, on conn: NWConnection, close: Bool) {
        if close {
            conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        } else {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}

// MARK: - Embedded Mobile Web Client HTML

private let webClientHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Shammy – Mac Remote Control</title>
  <link rel="icon" type="image/png" href="/icon.png">
  <link rel="apple-touch-icon" href="/icon.png">
  <style>
    :root {
      --bg: #090a0f;
      --card: #14151f;
      --accent: #38bdf8;
      --accent-glow: rgba(56, 189, 248, 0.25);
      --green: #10b981;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --border: rgba(255, 255, 255, 0.1);
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      -webkit-touch-callout: none;
      -webkit-user-select: none;
      user-select: none;
      touch-action: none;
    }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }
    /* Top Bar */
    header {
      height: 48px;
      background: rgba(18, 19, 28, 0.85);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 16px;
      z-index: 100;
      flex-shrink: 0;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 8px;
      font-weight: 700;
      font-size: 17px;
      letter-spacing: -0.3px;
    }
    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--green);
      box-shadow: 0 0 10px var(--green);
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.6; transform: scale(0.85); }
    }
    .header-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .btn-pill {
      background: rgba(255, 255, 255, 0.08);
      border: 1px solid var(--border);
      color: var(--text);
      padding: 6px 12px;
      border-radius: 20px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 6px;
      transition: all 0.15s ease;
    }
    .btn-pill:active, .btn-pill.active {
      background: var(--accent);
      color: #000;
      border-color: var(--accent);
    }

    /* Screen Viewport */
    #viewport-container {
      flex: 1;
      width: 100%;
      position: relative;
      background: #000;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: hidden;
    }
    #screen {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      display: block;
      pointer-events: none;
      box-shadow: 0 4px 30px rgba(0, 0, 0, 0.8);
    }
    /* Touch Overlay */
    #touch-surface {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      z-index: 50;
      cursor: crosshair;
    }

    /* Floating Dock */
    #dock {
      position: absolute;
      bottom: 16px;
      left: 50%;
      transform: translateX(-50%);
      background: rgba(20, 21, 31, 0.9);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid var(--border);
      border-radius: 28px;
      padding: 6px 12px;
      display: flex;
      align-items: center;
      gap: 8px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.5);
      z-index: 90;
    }
    .dock-btn {
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid transparent;
      color: var(--text);
      padding: 8px 14px;
      border-radius: 18px;
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 4px;
      transition: all 0.15s;
    }
    .dock-btn:active, .dock-btn.active {
      background: var(--accent);
      color: #000;
    }

    /* Joystick */
    #joystick-container {
      display: none;
      position: absolute;
      bottom: 80px;
      left: 20px;
      z-index: 95;
      touch-action: none;
      user-select: none;
      -webkit-user-select: none;
    }
    #joystick-container.visible {
      display: block;
    }
    #joy-speed-btn {
      background: rgba(20, 21, 31, 0.9);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      border: 1px solid rgba(56, 189, 248, 0.4);
      color: #38bdf8;
      padding: 5px 12px;
      border-radius: 14px;
      font-size: 12px;
      font-weight: 700;
      cursor: pointer;
      box-shadow: 0 4px 12px rgba(0,0,0,0.5);
      transition: all 0.15s;
    }
    #joy-speed-btn:active {
      transform: scale(0.95);
      background: var(--accent);
      color: #000;
    }
    #joystick-base {
      width: 136px;
      height: 136px;
      border-radius: 50%;
      background: radial-gradient(circle at 50% 50%, rgba(26, 30, 48, 0.8), rgba(12, 14, 24, 0.94));
      border: 2px solid rgba(56, 189, 248, 0.45);
      box-shadow: 0 8px 30px rgba(0, 0, 0, 0.7), 0 0 20px rgba(56, 189, 248, 0.18), inset 0 0 24px rgba(0,0,0,0.6);
      position: relative;
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      touch-action: none;
    }
    .joy-cross-h {
      position: absolute;
      top: 50%;
      left: 18px;
      right: 18px;
      height: 1px;
      background: rgba(56, 189, 248, 0.25);
      transform: translateY(-50%);
      pointer-events: none;
    }
    .joy-cross-v {
      position: absolute;
      left: 50%;
      top: 18px;
      bottom: 18px;
      width: 1px;
      background: rgba(56, 189, 248, 0.25);
      transform: translateX(-50%);
      pointer-events: none;
    }
    #joystick-knob {
      position: absolute;
      width: 52px;
      height: 52px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #7dd3fc, #0284c7 65%, #0369a1);
      box-shadow: 0 4px 18px rgba(14, 165, 233, 0.65), 0 2px 6px rgba(0,0,0,0.4);
      border: 2px solid rgba(255, 255, 255, 0.4);
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      transition: box-shadow 0.1s;
      will-change: transform;
      pointer-events: none;
    }
    #joystick-knob.active {
      box-shadow: 0 0 28px rgba(56, 189, 248, 0.95), 0 4px 12px rgba(0,0,0,0.6);
      border-color: #fff;
    }

    /* Gamepad Action Buttons (dual-hand control) */
    #gamepad-actions {
      display: none;
      position: absolute;
      bottom: 80px;
      right: 20px;
      z-index: 95;
      flex-direction: column;
      gap: 12px;
      align-items: center;
      touch-action: none;
    }
    #gamepad-actions.visible {
      display: flex;
    }
    .game-btn {
      border-radius: 50%;
      font-weight: 800;
      border: 1px solid var(--border);
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 6px 20px rgba(0,0,0,0.55);
      backdrop-filter: blur(14px);
      -webkit-backdrop-filter: blur(14px);
      transition: transform 0.08s, background 0.12s;
      touch-action: none;
    }
    .game-btn:active {
      transform: scale(0.92);
    }
    .game-btn-l {
      width: 54px;
      height: 54px;
      background: rgba(56, 189, 248, 0.22);
      border-color: rgba(56, 189, 248, 0.5);
      color: #38bdf8;
      font-size: 16px;
    }
    .game-btn-l.dragging {
      background: var(--accent);
      color: #000;
      box-shadow: 0 0 22px var(--accent);
    }
    .game-btn-r {
      width: 44px;
      height: 44px;
      background: rgba(255, 255, 255, 0.1);
      color: var(--text);
      font-size: 14px;
    }

    /* Virtual Keyboard Drawer */
    #keyboard-drawer {
      position: absolute;
      bottom: 0;
      left: 0;
      width: 100%;
      background: rgba(14, 15, 24, 0.96);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border-top: 1px solid var(--border);
      padding: 12px 12px 28px 12px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      z-index: 110;
      transform: translateY(100%);
      transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1);
    }
    #keyboard-drawer.open {
      transform: translateY(0);
    }
    .kb-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0 4px 4px 4px;
    }
    .kb-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.8px;
    }
    .kb-close {
      background: none;
      border: none;
      color: var(--text-muted);
      font-size: 20px;
      padding: 4px 8px;
      cursor: pointer;
    }
    .kb-row {
      display: flex;
      gap: 6px;
      overflow-x: auto;
      scrollbar-width: none;
      -webkit-overflow-scrolling: touch;
      padding-bottom: 2px;
    }
    .kb-row::-webkit-scrollbar { display: none; }
    .key-btn {
      flex: 1;
      min-width: 44px;
      height: 42px;
      background: rgba(255, 255, 255, 0.08);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text);
      font-size: 14px;
      font-weight: 600;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      transition: all 0.1s;
    }
    .key-btn:active, .key-btn.active {
      background: var(--accent);
      color: #000;
      border-color: var(--accent);
      transform: scale(0.96);
    }
    .text-input-box {
      display: flex;
      gap: 8px;
      margin-top: 4px;
    }
    .text-input-box input {
      flex: 1;
      height: 40px;
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 0 12px;
      color: #fff;
      font-size: 15px;
      outline: none;
      user-select: text;
      -webkit-user-select: text;
    }
    .text-input-box button {
      background: var(--accent);
      color: #000;
      border: none;
      border-radius: 10px;
      padding: 0 16px;
      font-weight: 700;
      font-size: 14px;
      cursor: pointer;
    }
  </style>
</head>
<body>

  <!-- Top Bar -->
  <header>
    <div class="brand">
      <img src="/icon.png" alt="Shammy" style="width:26px; height:26px; border-radius:7px; object-fit:cover; box-shadow:0 2px 6px rgba(0,0,0,0.5);">
      <span class="status-dot"></span>
      <span>Shammy</span>
      <span id="ws-badge" style="display:none; font-size:11px; background:rgba(16,185,129,0.18); border:1px solid rgba(16,185,129,0.4); color:#34d399; padding:2px 8px; border-radius:12px; font-weight:600; margin-left:4px;">⚡ Realtime</span>
    </div>
    <div class="header-actions">
      <button id="btn-speed" class="btn-pill" onclick="cycleQuality()">⚡ 30 FPS</button>
      <button id="btn-mode" class="btn-pill" onclick="toggleMode()">
        <span id="mode-icon">👆</span>
        <span id="mode-text">Touch</span>
      </button>
      <button class="btn-pill" onclick="toggleFullscreen()">⛶ Fullscreen</button>
    </div>
  </header>

  <!-- Screen Viewport -->
  <div id="viewport-container">
    <div id="perm-banner" style="display:none; position:absolute; top:20px; z-index:80; background:rgba(239, 68, 68, 0.94); backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px); padding:14px 20px; border-radius:14px; color:#fff; text-align:center; max-width:88%; box-shadow:0 10px 30px rgba(0,0,0,0.6); border:1px solid rgba(255,255,255,0.2);">
      <button onclick="dismissBanner()" style="position:absolute; top:8px; right:10px; background:rgba(0,0,0,0.25); border:none; color:#fff; font-size:16px; font-weight:bold; border-radius:50%; width:24px; height:24px; line-height:22px; cursor:pointer;">✕</button>
      <div style="font-weight:700; font-size:15px; margin-bottom:4px;">🔒 Mac Screen Recording Permission Needed</div>
      <div style="font-size:12px; line-height:1.4; opacity:0.95;">On your Mac, open <b>System Settings → Privacy & Security → Screen Recording</b>, and turn on <b>Shammy</b>.</div>
      <div style="margin-top:10px; display:flex; justify-content:center; gap:8px;">
        <button onclick="dismissBanner()" style="background:#fff; color:#b91c1c; border:none; border-radius:12px; padding:6px 14px; font-size:12px; font-weight:700; cursor:pointer;">I Enabled It (Dismiss)</button>
        <button onclick="reloadStream()" style="background:rgba(255,255,255,0.2); color:#fff; border:1px solid rgba(255,255,255,0.4); border-radius:12px; padding:6px 14px; font-size:12px; font-weight:600; cursor:pointer;">↻ Refresh Stream</button>
      </div>
    </div>
    <img id="screen" src="/stream" alt="Mac Screen" onload="onStreamLoaded()">
    <div id="touch-surface"></div>
  </div>

  <!-- Joystick Container with Speed Toggle -->
  <div id="joystick-container">
    <div style="display:flex; justify-content:center; margin-bottom:8px;">
      <button id="joy-speed-btn" onclick="cycleJoySpeed()">⚡ Fast 2x</button>
    </div>
    <div id="joystick-base">
      <div class="joy-cross-h"></div>
      <div class="joy-cross-v"></div>
      <div id="joystick-knob"></div>
    </div>
  </div>

  <!-- Gamepad Action Buttons (Dual-hand control) -->
  <div id="gamepad-actions">
    <button id="btn-game-l" class="game-btn game-btn-l" onpointerdown="onGameLDown(event)" onpointerup="onGameLUp(event)">L</button>
    <button id="btn-game-r" class="game-btn game-btn-r" onclick="onGameRClick(event)">R</button>
  </div>

  <!-- Floating Dock -->
  <div id="dock">
    <button class="dock-btn" onclick="sendClick('left')">Left Click</button>
    <button class="dock-btn" onclick="sendClick('right')">Right Click</button>
    <button class="dock-btn" onclick="sendDoubleClick()">Double Click</button>
    <button id="btn-drag" class="dock-btn" onclick="toggleDrag()">Drag: Off</button>
    <button id="btn-joystick" class="dock-btn" onclick="toggleJoystick()">🕹️ Stick</button>
    <button class="dock-btn" onclick="toggleKeyboard()">⌨️ Keys</button>
  </div>

  <!-- Keyboard Drawer -->
  <div id="keyboard-drawer">
    <div class="kb-header">
      <span class="kb-title">Shortcuts & Control</span>
      <button class="kb-close" onclick="toggleKeyboard()">✕</button>
    </div>

    <!-- Quick Shortcuts Row -->
    <div class="kb-row">
      <button class="key-btn" onclick="sendShortcut('spotlight')">⌘ Space</button>
      <button class="key-btn" onclick="sendShortcut('appSwitcher')">⌘ Tab</button>
      <button class="key-btn" onclick="sendShortcut('copy')">⌘ C</button>
      <button class="key-btn" onclick="sendShortcut('paste')">⌘ V</button>
      <button class="key-btn" onclick="sendShortcut('close')">⌘ W</button>
      <button class="key-btn" onclick="sendShortcut('undo')">⌘ Z</button>
    </div>

    <!-- Functional Keys Row -->
    <div class="kb-row">
      <button class="key-btn" onclick="sendShortcut('escape')">Esc</button>
      <button class="key-btn" onclick="sendShortcut('tab')">Tab</button>
      <button class="key-btn" onclick="sendShortcut('enter')">Return ⏎</button>
      <button class="key-btn" onclick="sendShortcut('backspace')">⌫ Delete</button>
      <button class="key-btn" onclick="sendShortcut('arrowUp')">↑</button>
      <button class="key-btn" onclick="sendShortcut('arrowDown')">↓</button>
      <button class="key-btn" onclick="sendShortcut('arrowLeft')">←</button>
      <button class="key-btn" onclick="sendShortcut('arrowRight')">→</button>
    </div>

    <!-- Text Injection Field -->
    <div class="text-input-box">
      <input type="text" id="type-box" placeholder="Type text to send to Mac..." onkeydown="if(event.key==='Enter') sendTypedText()">
      <button onclick="sendTypedText()">Send</button>
    </div>
  </div>

  <script>
    const screenImg = document.getElementById('screen');
    const surface = document.getElementById('touch-surface');
    let isTrackpadMode = false;
    let isDragging = false;
    let lastX = 0, lastY = 0;
    let touchStartTime = 0;
    let hasMoved = false;

    let bannerDismissed = false;
    let streamHasFrames = false;

    // ── Low-Latency WebSocket Transport ─────────────────────────────────────
    let ws = null;
    let wsConnected = false;
    let isPostInFlight = false;
    let pendingPost = null;

    function initWS() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      try {
        ws = new WebSocket(`${proto}//${location.host}/ws`);
        ws.onopen = () => {
          wsConnected = true;
          const badge = document.getElementById('ws-badge');
          if (badge) badge.style.display = 'inline-block';
        };
        ws.onclose = () => {
          wsConnected = false;
          const badge = document.getElementById('ws-badge');
          if (badge) badge.style.display = 'none';
          setTimeout(initWS, 1200);
        };
        ws.onerror = () => {
          if (ws) ws.close();
        };
      } catch (err) {
        setTimeout(initWS, 1500);
      }
    }
    initWS();

    function sendInput(data) {
      if (ws && wsConnected && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(data));
        return;
      }
      // Non-blocking coalescing HTTP fallback
      if (isPostInFlight) {
        if (data.action === 'delta' && pendingPost && pendingPost.action === 'delta') {
          pendingPost.dx += data.dx;
          pendingPost.dy += data.dy;
        } else {
          pendingPost = data;
        }
        return;
      }
      isPostInFlight = true;
      fetch('/api/mouse', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      }).finally(() => {
        isPostInFlight = false;
        if (pendingPost) {
          const next = pendingPost;
          pendingPost = null;
          sendInput(next);
        }
      });
    }

    // ── Joystick Physics & Sensitivity ──────────────────────────────────────
    let joystickActive = false;
    let joystickVisible = false;
    let joystickTouchId = null;
    let joystickBaseRect = null;
    let joystickAnimFrame = null;
    let joyDX = 0, joyDY = 0; // -1 .. 1

    const joySpeedLevels = [
      { label: '⚡ Fast 2x', val: 2.0 },
      { label: '🚀 Ultra 3.5x', val: 3.5 },
      { label: '🎯 Precise 1x', val: 1.0 }
    ];
    let currentSpeedIdx = 0;
    let joySensitivity = 2.0;

    function cycleJoySpeed() {
      currentSpeedIdx = (currentSpeedIdx + 1) % joySpeedLevels.length;
      const s = joySpeedLevels[currentSpeedIdx];
      joySensitivity = s.val;
      document.getElementById('joy-speed-btn').textContent = s.label;
    }

    const joyContainer = document.getElementById('joystick-container');
    const joyBase      = document.getElementById('joystick-base');
    const joyKnob      = document.getElementById('joystick-knob');
    const JOY_RADIUS   = 44; // max displacement px

    function toggleJoystick() {
      joystickVisible = !joystickVisible;
      joyContainer.classList.toggle('visible', joystickVisible);
      document.getElementById('gamepad-actions').classList.toggle('visible', joystickVisible);
      document.getElementById('btn-joystick').classList.toggle('active', joystickVisible);
      if (!joystickVisible) stopJoystickLoop();
    }

    joyBase.addEventListener('touchstart', (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (joystickTouchId !== null) return;
      const t = e.changedTouches[0];
      joystickTouchId = t.identifier;
      joystickBaseRect = joyBase.getBoundingClientRect();
      joystickActive = true;
      joyKnob.classList.add('active');
      updateJoystickFromTouch(t);
      startJoystickLoop();
    }, { passive: false });

    joyBase.addEventListener('touchmove', (e) => {
      e.preventDefault();
      e.stopPropagation();
      for (let i = 0; i < e.changedTouches.length; i++) {
        if (e.changedTouches[i].identifier === joystickTouchId) {
          updateJoystickFromTouch(e.changedTouches[i]);
          break;
        }
      }
    }, { passive: false });

    function endJoystick(e) {
      e.preventDefault();
      e.stopPropagation();
      for (let i = 0; i < e.changedTouches.length; i++) {
        if (e.changedTouches[i].identifier === joystickTouchId) {
          joystickTouchId = null;
          joystickActive = false;
          joyDX = 0; joyDY = 0;
          joyKnob.classList.remove('active');
          joyKnob.style.transform = 'translate(-50%, -50%)';
          stopJoystickLoop();
          break;
        }
      }
    }
    joyBase.addEventListener('touchend',    endJoystick, { passive: false });
    joyBase.addEventListener('touchcancel', endJoystick, { passive: false });

    function updateJoystickFromTouch(t) {
      if (!joystickBaseRect) return;
      const cx = joystickBaseRect.left + joystickBaseRect.width / 2;
      const cy = joystickBaseRect.top  + joystickBaseRect.height / 2;
      let dx = t.clientX - cx;
      let dy = t.clientY - cy;
      const dist = Math.hypot(dx, dy);
      if (dist > JOY_RADIUS) {
        dx = (dx / dist) * JOY_RADIUS;
        dy = (dy / dist) * JOY_RADIUS;
      }
      joyDX = dx / JOY_RADIUS;
      joyDY = dy / JOY_RADIUS;
      joyKnob.style.transform = `translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px))`;
    }

    let lastJoyTime = 0;
    function startJoystickLoop() {
      lastJoyTime = performance.now();
      if (joystickAnimFrame) return;
      function loop(now) {
        const dt = Math.min(50, now - lastJoyTime);
        lastJoyTime = now;
        if (joystickActive) {
          const dist = Math.hypot(joyDX, joyDY);
          if (dist > 0.04) {
            // Progressive exponential curve: gentle touch = pixel precise, full push = rapid traversal
            const normDist = (dist - 0.04) / 0.96;
            const accel = Math.pow(normDist, 1.45);
            const baseSpeed = 1400 * joySensitivity;
            const speed = accel * baseSpeed;
            const step = speed * (dt / 1000);
            const dx = (joyDX / dist) * step;
            const dy = (joyDY / dist) * step;
            sendInput({ action: 'delta', dx: dx, dy: dy });
          }
        }
        joystickAnimFrame = requestAnimationFrame(loop);
      }
      joystickAnimFrame = requestAnimationFrame(loop);
    }

    function stopJoystickLoop() {
      if (joystickAnimFrame) {
        cancelAnimationFrame(joystickAnimFrame);
        joystickAnimFrame = null;
      }
    }

    // ── Gamepad Quick Action Buttons (Left / Right Click) ───────────────────
    let gameLPressTimer = null;
    let isGameLDragging = false;

    function onGameLDown(e) {
      e.preventDefault();
      isGameLDragging = false;
      gameLPressTimer = setTimeout(() => {
        isGameLDragging = true;
        document.getElementById('btn-game-l').classList.add('dragging');
        sendInput({ action: 'button', button: 'left', pressed: true, normX: -1, normY: -1 });
      }, 280);
    }

    function onGameLUp(e) {
      e.preventDefault();
      if (gameLPressTimer) {
        clearTimeout(gameLPressTimer);
        gameLPressTimer = null;
      }
      if (isGameLDragging) {
        isGameLDragging = false;
        document.getElementById('btn-game-l').classList.remove('dragging');
        sendInput({ action: 'button', button: 'left', pressed: false, normX: -1, normY: -1 });
      } else {
        sendInput({ action: 'click', button: 'left', normX: -1, normY: -1 });
      }
    }

    function onGameRClick(e) {
      e.preventDefault();
      sendInput({ action: 'click', button: 'right', normX: -1, normY: -1 });
    }

    // ── Stream Status & Permissions ─────────────────────────────────────────
    function dismissBanner() {
      bannerDismissed = true;
      const banner = document.getElementById('perm-banner');
      if (banner) banner.style.display = 'none';
    }

    function reloadStream() {
      const img = document.getElementById('screen');
      if (img) img.src = '/stream?t=' + Date.now();
      checkStatus();
    }

    function onStreamLoaded() {
      streamHasFrames = true;
      const banner = document.getElementById('perm-banner');
      if (banner) banner.style.display = 'none';
    }

    function checkStatus() {
      fetch('/api/status')
        .then(r => r.json())
        .then(data => {
          const banner = document.getElementById('perm-banner');
          if (banner) {
            if (bannerDismissed || streamHasFrames || data.screenRecordingGranted === true || data.isCapturing === true) {
              banner.style.display = 'none';
            } else if (data.screenRecordingGranted === false) {
              banner.style.display = 'block';
            }
          }
        })
        .catch(() => {});
    }
    setInterval(checkStatus, 3000);
    checkStatus();

    // ── Modes & Quality ─────────────────────────────────────────────────────
    function toggleMode() {
      isTrackpadMode = !isTrackpadMode;
      document.getElementById('mode-icon').textContent = isTrackpadMode ? '🖱️' : '👆';
      document.getElementById('mode-text').textContent = isTrackpadMode ? 'Trackpad' : 'Touch';
    }

    function toggleDrag() {
      isDragging = !isDragging;
      const btn = document.getElementById('btn-drag');
      btn.textContent = isDragging ? 'Drag: ON' : 'Drag: Off';
      btn.classList.toggle('active', isDragging);
      sendInput({ action: 'button', button: 'left', pressed: isDragging, normX: -1, normY: -1 });
    }

    function toggleKeyboard() {
      document.getElementById('keyboard-drawer').classList.toggle('open');
    }

    function toggleFullscreen() {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {});
      } else {
        document.exitFullscreen().catch(() => {});
      }
    }

    let qualityLevels = [
      { name: '⚡ 30 FPS', fps: 30, quality: 0.5 },
      { name: '🚀 60 FPS', fps: 60, quality: 0.4 },
      { name: '💎 Crisp', fps: 20, quality: 0.75 }
    ];
    let currentQualityIdx = 0;

    function cycleQuality() {
      currentQualityIdx = (currentQualityIdx + 1) % qualityLevels.length;
      const q = qualityLevels[currentQualityIdx];
      document.getElementById('btn-speed').textContent = q.name;
      sendInput({ action: 'settings', fps: q.fps, quality: q.quality });
    }

    // ── Touch & Trackpad Gestures ───────────────────────────────────────────
    let lastNormX = 0.5, lastNormY = 0.5;

    function getNormalizedCoords(clientX, clientY) {
      const rect = screenImg.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return { x: 0.5, y: 0.5 };
      let nx = (clientX - rect.left) / rect.width;
      let ny = (clientY - rect.top) / rect.height;
      return { x: Math.max(0, Math.min(1, nx)), y: Math.max(0, Math.min(1, ny)) };
    }

    surface.addEventListener('touchstart', (e) => {
      e.preventDefault();
      touchStartTime = Date.now();
      hasMoved = false;
      const t = e.touches[0];
      lastX = t.clientX;
      lastY = t.clientY;
      const norm = getNormalizedCoords(t.clientX, t.clientY);
      lastNormX = norm.x;
      lastNormY = norm.y;

      if (!isTrackpadMode && !isDragging) {
        sendInput({ action: 'move', normX: norm.x, normY: norm.y });
      }
    }, { passive: false });

    surface.addEventListener('touchmove', (e) => {
      e.preventDefault();
      hasMoved = true;
      if (e.touches.length === 1) {
        const t = e.touches[0];
        if (isTrackpadMode) {
          const rawDx = (t.clientX - lastX);
          const rawDy = (t.clientY - lastY);
          lastX = t.clientX;
          lastY = t.clientY;
          const dist = Math.hypot(rawDx, rawDy);
          const accel = Math.min(2.8, 1.0 + dist / 9.0);
          const factor = 1.3 * (joySensitivity > 2 ? 1.6 : 1.1) * accel;
          sendInput({ action: 'delta', dx: rawDx * factor, dy: rawDy * factor });
        } else {
          const norm = getNormalizedCoords(t.clientX, t.clientY);
          lastNormX = norm.x;
          lastNormY = norm.y;
          sendInput({ action: 'move', normX: norm.x, normY: norm.y });
        }
      } else if (e.touches.length === 2) {
        // Two-finger scroll
        const dy = (e.touches[0].clientY - lastY) * 1.5;
        const dx = (e.touches[0].clientX - lastX) * 1.5;
        lastY = e.touches[0].clientY;
        lastX = e.touches[0].clientX;
        sendInput({ action: 'scroll', deltaX: -dx, deltaY: dy });
      }
    }, { passive: false });

    surface.addEventListener('touchend', (e) => {
      e.preventDefault();
      const duration = Date.now() - touchStartTime;
      if (duration < 250 && !hasMoved && !isDragging) {
        if (isTrackpadMode) {
          sendInput({ action: 'click', button: 'left', normX: -1, normY: -1 });
        } else {
          sendInput({ action: 'click', button: 'left', normX: lastNormX, normY: lastNormY });
        }
      }
    }, { passive: false });

    function sendClick(btn) {
      sendInput({ action: 'click', button: btn, normX: -1, normY: -1 });
    }

    function sendDoubleClick() {
      sendInput({ action: 'doubleClick', normX: -1, normY: -1 });
    }

    function sendShortcut(name) {
      sendInput({ action: 'shortcut', name: name });
    }

    function sendTypedText() {
      const box = document.getElementById('type-box');
      const text = box.value;
      if (text) {
        sendInput({ action: 'text', text: text });
        box.value = '';
      }
    }
  </script>
</body>
</html>
"""
