// ConnectView.swift
// MacLink – iOS Client
// Connection / setup screen: host address, port, shared secret, connect button.

import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var session: ClientSession
    @State private var showSecret = false
    @FocusState private var focusedField: Field?

    private enum Field { case host, port, secret }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // MARK: Header
                VStack(spacing: 12) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.white)
                    Text("Shammy")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Remote desktop for your Mac")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                .padding(.bottom, 40)

                // MARK: Form card
                VStack(spacing: 0) {
                    // Host
                    fieldRow(icon: "network", label: "Host Address") {
                        TextField("100.x.x.x or hostname", text: $session.hostAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .port }
                    }

                    Divider().background(Color(white: 0.2))

                    // Port
                    fieldRow(icon: "number", label: "Port") {
                        TextField("55100", value: $session.controlPort, format: .number)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                    }

                    Divider().background(Color(white: 0.2))

                    // Secret
                    fieldRow(icon: "key.fill", label: "Shared Secret") {
                        HStack {
                            if showSecret {
                                TextField("Paste secret from Mac app", text: $session.sharedSecret)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .secret)
                            } else {
                                SecureField("Paste secret from Mac app", text: $session.sharedSecret)
                                    .focused($focusedField, equals: .secret)
                            }
                            Button {
                                showSecret.toggle()
                            } label: {
                                Image(systemName: showSecret ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .background(Color(white: 0.08))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(white: 0.2), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)

                // MARK: Status / error
                if case .error(let msg) = session.state {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                if case .reconnecting(let n) = session.state {
                    Text("Reconnecting… attempt \(n) of \(MacLinkConstants.maxReconnectAttempts)")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .padding(.top, 16)
                }

                // MARK: Connect button
                connectButton
                    .padding(.top, 28)
                    .padding(.horizontal, 20)

                // MARK: Tips
                tipsView
                    .padding(.top, 32)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Connect / Cancel button

    @ViewBuilder
    var connectButton: some View {
        switch session.state {
        case .disconnected, .error:
            Button {
                focusedField = nil
                session.connect()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Connect")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .foregroundStyle(.black)
                .cornerRadius(14)
            }
            .disabled(session.hostAddress.isEmpty || session.sharedSecret.isEmpty)

        case .connecting, .authenticating, .reconnecting:
            Button {
                session.disconnect()
            } label: {
                HStack {
                    ProgressView().tint(.white)
                    Text(session.state.displayString)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(white: 0.2))
                .foregroundStyle(.white)
                .cornerRadius(14)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Tips

    var tipsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETUP GUIDE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            TipRow(number: "1", text: "Open Shammy on your Mac and start a session.")
            TipRow(number: "2", text: "Copy the Connection Address and Shared Secret from the Mac app.")
            TipRow(number: "3", text: "For cross-network access, install Tailscale on both devices and use the Tailscale IP (100.x.x.x).")
            TipRow(number: "4", text: "On the same Wi-Fi, use the Local IP shown in the Mac app.")
        }
        .padding(16)
        .background(Color(white: 0.06))
        .cornerRadius(12)
    }

    // MARK: - Field row helper

    private func fieldRow<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                content()
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

struct TipRow: View {
    let number: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 18, height: 18)
                .background(Color(white: 0.6))
                .cornerRadius(9)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
