import AppKit
import SwiftUI

/// Menu-bar agent entry point (spec §2). `LSUIElement` is set in Info.plist, so
/// there is no Dock icon and no main window — only the menu-bar item below.
///
/// This is the Phase 0 skeleton: it builds, signs, and launches as a menu-bar
/// agent. The menu items are wired to real behavior in later phases
/// (Translate → Phase 2 capture/trigger; Settings… → Phase 1 settings window).
@main
struct MacLingoApp: App {
    var body: some Scene {
        MenuBarExtra("MacLingo", systemImage: "character.bubble") {
            Button("Translate Selection") {
                // TODO(Phase 2): issue an OperationID and run capture + translate.
            }
            .keyboardShortcut("t", modifiers: [.option, .command])

            Divider()

            Button("Settings…") {
                // TODO(Phase 1): open the SwiftUI settings window.
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit MacLingo") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
