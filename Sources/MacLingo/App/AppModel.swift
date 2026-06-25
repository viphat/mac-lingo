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

    /// Trigger → capture → translate → present pipeline (spec §3.1).
    let coordinator: TranslationCoordinator

    /// Result of the most recent launch migration, surfaced to the UI when the
    /// store had to be reset (spec §5.5).
    @Published private(set) var migrationOutcome: SettingsMigrationOutcome = .upToDate

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
        let presenter = ModalPresenter(services: DefaultTranslationServices())
        self.coordinator = TranslationCoordinator(
            capturer: SelectionCapturer(), settings: settings, presenter: presenter)
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

    /// Hotkey / menu entry point. Re-checks Accessibility, then hands off to the
    /// coordinator (capture → translate → present). Re-triggering cancels any
    /// in-flight capture so a superseded one is discarded (spec §3.1, §4.3, §5.3).
    func handleTranslateTrigger() {
        guard permissions.recheck() else {
            log.notice("translate trigger ignored: Accessibility not granted")
            return
        }
        coordinator.handleTrigger()
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
