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
            Button("Translate Selection") {
                model.handleTranslateTrigger()
            }

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit MacLingo") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView(settings: model.settings, permissions: model.permissions, model: model)
        }
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
