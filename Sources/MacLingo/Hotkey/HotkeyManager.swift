import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    /// Global translate-selection hotkey. Default `⌥⌘T` (spec §4.2). The user can
    /// re-record it; `KeyboardShortcuts` persists the chosen shortcut itself.
    static let translateSelection = Self(
        "translateSelection",
        default: .init(.t, modifiers: [.option, .command]))
}

/// Owns the global hotkey via the `KeyboardShortcuts` package (spec §4.2). The
/// package persists the recorded shortcut; this manager (re-)attaches the trigger
/// handler, which is what launch reconciliation re-runs (spec §5.5a).
@MainActor
final class HotkeyManager: HotkeyRegistering {
    private var onTrigger: (() -> Void)?
    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "Hotkey")

    /// Set the action run when the hotkey fires, then attach the listener.
    func setTriggerHandler(_ handler: @escaping () -> Void) {
        onTrigger = handler
        try? reregister()
    }

    /// Attach (or re-attach) the key-down listener for the persisted shortcut.
    func reregister() throws {
        KeyboardShortcuts.onKeyDown(for: .translateSelection) { [weak self] in
            self?.log.debug("translate hotkey fired")
            self?.onTrigger?()
        }
    }
}
