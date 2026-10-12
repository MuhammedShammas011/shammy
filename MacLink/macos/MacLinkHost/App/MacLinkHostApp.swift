// MacLinkHostApp.swift
// MacLink – macOS Host Application
// Entry point. Creates the SessionManager singleton and launches the main window.

import SwiftUI
import AppKit

@main
struct MacLinkHostApp: App {

    @StateObject private var session = SessionManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Shammy") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 600, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Copy Connection Address") {
                    let addr = session.connectionAddress
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(addr, forType: .string)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(session.connectionAddress.isEmpty)

                Divider()

                Button("Disconnect Client") {
                    session.stopSession()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session.state != .connected)
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImg = NSImage(contentsOf: iconUrl) {
            NSApplication.shared.applicationIconImage = iconImg
        } else if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                  let iconImg = NSImage(contentsOf: iconUrl) {
            NSApplication.shared.applicationIconImage = iconImg
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionManager.shared.stopSession()
    }
}
