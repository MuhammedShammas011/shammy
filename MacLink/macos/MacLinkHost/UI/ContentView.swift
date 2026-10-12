// ContentView.swift
// MacLink – macOS Host
// Main window UI: shows permission status, connection info, session controls,
// and a live FPS indicator. Design: dark, minimal, restrained grey/white palette.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var session: SessionManager
    @State private var showSecret = false
    @State private var copiedAddress = false

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                Divider().opacity(0.3)
                ScrollView {
                    VStack(spacing: 20) {
                        permissionsCard
                        connectionCard
                        sessionCard
                        if session.state == .connected {
                            liveCard
                        }
                        secretCard
                    }
                    .padding(24)
                }
            }
        }
        .onAppear {
            session.checkPermissions()
            session.updateNetworkAddresses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.checkPermissions()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            session.checkPermissions()
        }
    }

    // MARK: - Header

    private var appIconImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    var headerView: some View {
        HStack(spacing: 12) {
            if let icon = appIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "display")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Shammy")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            StatusBadge(state: session.state)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(white: 0.08))
    }

    // MARK: - Permissions card

    var permissionsCard: some View {
        GroupCard(title: "Permissions") {
            PermissionRow(
                icon: "camera.viewfinder",
                label: "Screen Recording",
                granted: session.screenCaptureAuthorized
            ) {
                session.requestScreenRecordingPermission()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    session.checkPermissions()
                }
            }

            Divider().opacity(0.2)

            PermissionRow(
                icon: "keyboard",
                label: "Accessibility (Input Control)",
                granted: session.accessibilityAuthorized
            ) {
                session.requestAccessibilityPermission()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    session.checkPermissions()
                }
            }
        }
    }

    // MARK: - Connection card

    var connectionCard: some View {
        GroupCard(title: "Network") {
            InfoRow(label: "Local IP", value: session.localIP.isEmpty ? "–" : session.localIP)
            Divider().opacity(0.2)
            InfoRow(label: "Tailscale IP",
                    value: session.tailscaleIP.isEmpty ? "Not connected" : session.tailscaleIP,
                    valueColor: session.tailscaleIP.isEmpty ? .secondary : .green)
            Divider().opacity(0.2)
            InfoRow(label: "Control Port", value: "\(session.controlPort)")
            Divider().opacity(0.2)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Remote (Phone Chrome / Safari)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                    Text(session.webURLString.isEmpty ? "–" : session.webURLString)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                Spacer()
                if !session.webURLString.isEmpty {
                    Button(copiedAddress ? "Copied!" : "Copy Web URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.webURLString, forType: .string)
                        withAnimation { copiedAddress = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copiedAddress = false }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color.cyan.opacity(0.12))
            .cornerRadius(8)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TCP Address (Native iOS App)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(session.connectionAddress.isEmpty ? "–" : session.connectionAddress)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button("Refresh Network Info") {
                session.updateNetworkAddresses()
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    // MARK: - Session card

    var sessionCard: some View {
        GroupCard(title: "Session") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(session.state.displayString)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(stateColor(session.state))
                }
                Spacer()
                sessionButton
            }

            if !session.connectedDeviceName.isEmpty {
                Divider().opacity(0.2)
                InfoRow(label: "Connected Device", value: session.connectedDeviceName)
            }

            if !session.lastError.isEmpty {
                Divider().opacity(0.2)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 13))
                    Text(session.lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    var sessionButton: some View {
        switch session.state {
        case .idle:
            Button("Start Session") {
                session.startSession()
            }
            .buttonStyle(PrimaryButtonStyle())

        case .listening, .handshaking:
            Button("Cancel") { session.stopSession() }
                .buttonStyle(DestructiveButtonStyle())

        case .connected:
            Button("Disconnect") { session.stopSession() }
                .buttonStyle(DestructiveButtonStyle())

        case .error:
            Button("Retry") { session.startSession() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: - Live stats card

    var liveCard: some View {
        GroupCard(title: "Live") {
            HStack {
                StatBox(label: "FPS", value: String(format: "%.0f", session.framesPerSecond))
                Divider().frame(height: 40)
                StatBox(label: "Mode", value: "JPEG")   // updated when H.264 enabled
            }
        }
    }

    // MARK: - Shared secret card

    var secretCard: some View {
        GroupCard(title: "Authentication") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shared secret — enter this in the iPhone app:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    if showSecret {
                        Text(loadSecret())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: 20))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showSecret ? "Hide" : "Reveal") {
                        showSecret.toggle()
                    }
                    .controlSize(.small)

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(loadSecret(), forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            Divider().opacity(0.2)
            Button("Generate New Secret") {
                regenerateSecret()
            }
            .controlSize(.small)
            .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private func stateColor(_ state: SessionState) -> Color {
        switch state {
        case .idle:         return .secondary
        case .listening:    return .orange
        case .handshaking:  return .yellow
        case .connected:    return .green
        case .error:        return .red
        }
    }

    private func loadSecret() -> String {
        UserDefaults.standard.string(forKey: "maclink.shared_secret") ?? "–"
    }

    private func regenerateSecret() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(secret, forKey: "maclink.shared_secret")
    }
}

// MARK: - Sub-components

struct StatusBadge: View {
    let state: SessionState
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
                .shadow(color: badgeColor.opacity(0.8), radius: 4)
            Text(shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.15).cornerRadius(20))
    }

    var badgeColor: Color {
        switch state {
        case .idle:         return .gray
        case .listening:    return .orange
        case .handshaking:  return .yellow
        case .connected:    return .green
        case .error:        return .red
        }
    }

    var shortLabel: String {
        switch state {
        case .idle:         return "Idle"
        case .listening:    return "Waiting"
        case .handshaking:  return "Auth"
        case .connected:    return "Live"
        case .error:        return "Error"
        }
    }
}

struct GroupCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            content()
        }
        .padding(18)
        .background(Color(white: 0.1).cornerRadius(12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(white: 0.18), lineWidth: 0.5)
        )
    }
}

struct PermissionRow: View {
    let icon: String
    let label: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access", action: action)
                    .controlSize(.small)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }
}

struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.8 : 1.0))
            .cornerRadius(8)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.red.opacity(configuration.isPressed ? 0.7 : 1.0))
            .cornerRadius(8)
    }
}
