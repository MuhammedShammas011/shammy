// RootView.swift
// MacLink – iOS Client
// Root navigation: shows ConnectView when disconnected, RemoteDesktopView when connected.

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: ClientSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.state.isConnected {
                RemoteDesktopView()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.state.isConnected)
    }
}
