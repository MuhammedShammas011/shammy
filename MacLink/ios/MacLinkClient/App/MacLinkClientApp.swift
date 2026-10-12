// MacLinkClientApp.swift
// MacLink – iOS Client Application
// Entry point. Creates the ClientSession singleton and shows the root view.

import SwiftUI

@main
struct MacLinkClientApp: App {
    @StateObject private var session = ClientSession.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
