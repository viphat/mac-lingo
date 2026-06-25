import OSLog
import SwiftUI

/// Owns the shared, long-lived collaborators and runs launch bootstrap. Injected
/// into SwiftUI views as an `EnvironmentObject`. Feature behavior (capture,
/// translation, modal) is wired in here in later phases.
@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let permissions: PermissionsCoordinator
    let keychain: KeychainStoring
    let hotkey: HotkeyManager
    let loginItem: LoginItemController
    let reconciler: StateReconciler

    /// Per-trigger operation identity issuer (spec §3.1, §5.3). An `OperationID` is
    /// opened **before** capture; the full `RequestRegistry` is layered on in Phase 3.
    let operationIDs = OperationIDIssuer()
    /// Serialized, ownership-safe text capture (spec §4.3).
    let capturer = SelectionCapturer()

    /// Result of the most recent launch migration, surfaced to the UI when the
    /// store had to be reset (spec §5.5).
    @Published private(set) var migrationOutcome: SettingsMigrationOutcome = .upToDate

    /// In-flight capture/translate task. Re-triggering cancels it so a superseded
    /// capture is discarded and its cleanup runs (spec §4.3, §5.3).
    private var triggerTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "AppModel")

    init() {
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let hotkey = HotkeyManager()
        let loginItem = LoginItemController()
        self.settings = settings
        self.keychain = keychain
        self.hotkey = hotkey
        self.loginItem = loginItem
        self.permissions = PermissionsCoordinator()
        self.reconciler = StateReconciler(
            settings: settings, keychain: keychain, hotkey: hotkey, loginItem: loginItem)
    }

    /// Run once at launch: migrate settings (fail-safe), reconcile system/provider
    /// state, attach the hotkey trigger, and read live permission state.
    func bootstrap() {
        migrationOutcome = settings.migrateIfNeeded()
        if case .resetToDefaults(let backupURL) = migrationOutcome {
            log.error("settings were reset to defaults; backup: \(backupURL?.path ?? "none", privacy: .public)")
        }
        reconciler.reconcileAtLaunch()
        hotkey.setTriggerHandler { [weak self] in self?.handleTranslateTrigger() }
        permissions.recheck()
    }

    /// Hotkey / menu entry point. Opens an `OperationID` *before* capture, runs the
    /// serialized capture, and (Phase 2) logs a debug summary. Re-triggering cancels
    /// any in-flight capture so it is superseded and discarded (spec §4.3, §5.3).
    func handleTranslateTrigger() {
        guard permissions.recheck() else {
            log.notice("translate trigger ignored: Accessibility not granted")
            return
        }
        let method = settings.captureMethod
        triggerTask?.cancel()
        triggerTask = Task { [weak self] in
            guard let self else { return }
            let operationID = await self.operationIDs.next()
            let captured = await self.capturer.capture(method: method)
            if Task.isCancelled { return }
            self.reportCapture(operationID: operationID, captured: captured)
        }
    }

    /// Phase 2 debug sink for a completed capture. Phase 3 replaces this with the
    /// translation coordinator + modal presentation.
    private func reportCapture(operationID: OperationID, captured: CapturedSelection?) {
        guard let captured else {
            log.notice("op \(operationID, privacy: .public): no text selected")
            return
        }
        let hasRich = captured.rich != nil
        let chars = captured.plainText.count
        let summary = "op \(operationID): captured \(chars) chars, rich=\(hasRich)"
        log.notice("\(summary, privacy: .public)")
        // TODO(Phase 3): build SelectionSnapshot → translate → present modal.
    }

    /// Toggle launch-at-login with the atomic write contract (spec §5.5): apply the
    /// `SMAppService` op first; persist only on success.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try settings.applyAtomic(
                enabled,
                system: { try loginItem.setEnabled($0) },
                persist: { settings.launchAtLogin = $0 })
        } catch {
            log.error("launch-at-login change failed: \(String(describing: error), privacy: .public)")
        }
    }
}
