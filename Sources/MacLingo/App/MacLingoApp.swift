import AppKit
import SwiftUI

/// Menu-bar agent entry point (spec §2). `LSUIElement` is set in Info.plist, so
/// there is no Dock icon and no main window — only the menu-bar item and the
/// Settings window below.
@main
struct MacLingoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model

        MenuBarExtra("MacLingo", systemImage: "character.bubble") {
            MenuContent(model: model)
        }

        Settings {
            SettingsView(settings: model.settings, permissions: model.permissions, model: model)
        }
    }
}

/// The menu-bar dropdown. Extracted into a `View` so it can use the
/// `\.openSettings` action — `SettingsLink` alone doesn't reliably surface an
/// **already-open** Settings window for an `LSUIElement` agent (the app isn't
/// activated, so the existing window stays buried behind the frontmost app).
private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Translate Selection") {
            model.handleTranslateTrigger()
        }

        Button("Settings…") {
            showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check for Updates…") {
            model.checkForUpdates()
        }

        Divider()

        Button("Quit MacLingo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Open (or re-open) Settings and force it to the foreground. As an agent app
    /// we must activate ourselves and explicitly order the Settings window front,
    /// otherwise a pre-existing window is left behind whatever app is frontmost.
    private func showSettings() {
        openSettings()
        NSApp.activate()
        // The window exists after `openSettings()` returns to the run loop; surface
        // it on the next tick.
        DispatchQueue.main.async {
            settingsWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    /// Best-effort lookup of the SwiftUI Settings window. The internal identifier
    /// has been stable across recent macOS releases; we fall back to the app's
    /// titled, key-capable window so a future rename still surfaces *something*.
    private func settingsWindow() -> NSWindow? {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
        }) {
            return window
        }
        return NSApp.windows.first { $0.canBecomeKey && !$0.title.isEmpty }
    }
}

/// Owns the single `AppModel` and runs launch bootstrap (migration →
/// reconciliation → hotkey) once the app finishes launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.bootstrap()
    }
}
