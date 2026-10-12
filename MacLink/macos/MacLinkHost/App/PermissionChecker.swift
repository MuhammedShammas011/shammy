// PermissionChecker.swift
// MacLink – macOS Host
// Checks and requests Screen Recording and Accessibility permissions.

import AppKit
import ScreenCaptureKit

struct PermissionChecker {

    // MARK: - Screen Recording

    /// Returns true if the app has been granted screen recording permission.
    static func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Opens System Settings and prompts for screen recording access if not already granted.
    static func requestScreenRecordingPermission() {
        guard !hasScreenRecordingPermission() else { return }
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility

    /// Returns true if the app is trusted for Accessibility (required for CGEvent injection).
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Opens the Accessibility pane and, if not trusted, prompts via system dialog.
    static func requestAccessibilityPermission() {
        guard !hasAccessibilityPermission() else { return }
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
