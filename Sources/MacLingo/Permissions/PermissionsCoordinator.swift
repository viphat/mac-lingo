import AppKit
import ApplicationServices
import OSLog

/// Accessibility permission gate (spec §4.1, §11). MacLingo needs Accessibility to
/// synthesize the copy keystroke and read selected text. This coordinator detects
/// the permission, drives onboarding, deep-links to System Settings, and supports
/// a live re-check (on settings focus and at trigger time).
@MainActor
final class PermissionsCoordinator: ObservableObject {

    /// Whether Accessibility is currently granted. Drives the onboarding UI.
    @Published private(set) var isAccessibilityTrusted: Bool

    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "Permissions")

    init() {
        self.isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// Re-read the live permission state. Call on settings focus and at trigger
    /// time so a mid-session grant/revoke is reflected immediately (spec §11).
    @discardableResult
    func recheck() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
            log.notice("Accessibility trust changed: \(trusted, privacy: .public)")
        }
        return trusted
    }

    /// Prompt the system Accessibility dialog (shown once per session by macOS) and
    /// return the current trust state. Use during onboarding.
    @discardableResult
    func promptForAccessibility() -> Bool {
        // Use the documented key value directly; the SDK global
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable mutable global under
        // Swift 6 strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityTrusted = trusted
        return trusted
    }

    /// Deep-link to *System Settings → Privacy & Security → Accessibility*.
    func openAccessibilitySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
