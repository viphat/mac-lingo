import Foundation
import OSLog

/// Re-registers the global hotkey from the persisted shortcut (spec §5.5a).
@MainActor
protocol HotkeyRegistering {
    func reregister() throws
}

/// Controls the `SMAppService` login item (spec §5.5b). Abstracted so the
/// reconciler is testable without touching the real login-item database.
@MainActor
protocol LoginItemControlling {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

/// What launch reconciliation did — returned for logging and asserted in tests.
struct ReconciliationReport: Equatable, Sendable {
    var hotkeyReregistered = false
    var hotkeyError: String?
    var loginItemRepaired = false
    var loginItemError: String?
    var hasKeyProviderCorrected = false
    var hasKeyCloudCorrected = false
    var defaultEngineCorrectedFrom: DefaultEngine?
    var defaultEngineCorrectedTo: DefaultEngine?
    var autoEnhanceDisabled = false
    var notes: [String] = []
}

/// Launch + live reconciliation of system/provider state against the persisted
/// desired state (spec §5.5). Repairs mismatches and logs them; never trusts a
/// `hasKey` flag over the Keychain, and never leaves an unconfigured default
/// engine selected.
@MainActor
final class StateReconciler {
    private let settings: SettingsStore
    private let keychain: KeychainStoring
    private let hotkey: HotkeyRegistering
    private let loginItem: LoginItemControlling
    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "StateReconciler")

    init(
        settings: SettingsStore,
        keychain: KeychainStoring,
        hotkey: HotkeyRegistering,
        loginItem: LoginItemControlling
    ) {
        self.settings = settings
        self.keychain = keychain
        self.hotkey = hotkey
        self.loginItem = loginItem
    }

    /// Run at startup (spec §5.5). Order: hotkey → login item → Keychain↔hasKey →
    /// default-engine validity.
    @discardableResult
    func reconcileAtLaunch() -> ReconciliationReport {
        var report = ReconciliationReport()
        reconcileHotkey(&report)
        reconcileLoginItem(&report)
        reconcileKeychainFlags(&report)
        reconcileDefaultEngine(&report)
        reconcileAutoEnhance(&report)
        if !report.notes.isEmpty {
            log.notice("Launch reconciliation made repairs: \(report.notes, privacy: .public)")
        }
        return report
    }

    /// Live (in-session) provider reconciliation (spec §5.5): a key/model/provider
    /// change, a failed Validate, or a runtime 401/403. Re-derives the configured
    /// set, repairs a stale default engine, and disables auto-enhance if its
    /// provider is no longer valid. The caller bumps `providerConfigRevision`,
    /// updates the service registry, and fans out to live panels.
    @discardableResult
    func reconcileProvidersLive() -> ReconciliationReport {
        var report = ReconciliationReport()
        reconcileKeychainFlags(&report)
        reconcileDefaultEngine(&report)
        reconcileAutoEnhance(&report)
        if !report.notes.isEmpty {
            log.notice("Live reconciliation made repairs: \(report.notes, privacy: .public)")
        }
        return report
    }

    // MARK: - (a) Hotkey

    private func reconcileHotkey(_ report: inout ReconciliationReport) {
        do {
            try hotkey.reregister()
            report.hotkeyReregistered = true
        } catch {
            report.hotkeyError = String(describing: error)
            report.notes.append("hotkey re-registration failed")
        }
    }

    // MARK: - (b) Login item — desired state wins; clear desired if system refuses

    private func reconcileLoginItem(_ report: inout ReconciliationReport) {
        let desired = settings.launchAtLogin
        let actual = loginItem.isEnabled()
        guard desired != actual else { return }

        do {
            // Apply the system op first; persistence already reflects `desired`.
            try loginItem.setEnabled(desired)
            report.loginItemRepaired = true
            report.notes.append("login item set to \(desired) to match desired state")
        } catch {
            // System refused: clear the desired value to match reality (no
            // optimistic persistence — spec §5.5).
            settings.launchAtLogin = actual
            report.loginItemError = String(describing: error)
            report.notes.append("login item repair failed; desired reset to \(actual)")
        }
    }

    // MARK: - (c) Keychain presence is the source of truth for hasKey flags

    private func reconcileKeychainFlags(_ report: inout ReconciliationReport) {
        let providerPresent = keychain.hasKey(.aiProvider)
        if settings.hasKeyProvider != providerPresent {
            settings.hasKeyProvider = providerPresent
            report.hasKeyProviderCorrected = true
            report.notes.append("hasKeyProvider corrected to \(providerPresent)")
        }

        let cloudPresent = keychain.hasKey(.googleCloud)
        if settings.hasKeyCloud != cloudPresent {
            settings.hasKeyCloud = cloudPresent
            report.hasKeyCloudCorrected = true
            report.notes.append("hasKeyCloud corrected to \(cloudPresent)")
        }
    }

    // MARK: - (d) Default engine must be configured (presence, not validity)

    private func reconcileDefaultEngine(_ report: inout ReconciliationReport) {
        let configured = currentConfiguration()
        let preferred = settings.defaultEngine
        guard !EngineResolver.isAvailable(preferred, available: configured) else { return }

        let resolved = EngineResolver.resolve(preferred: preferred, available: configured)
        let corrected = EngineResolver.defaultEngine(for: resolved)
        settings.defaultEngine = corrected
        report.defaultEngineCorrectedFrom = preferred
        report.defaultEngineCorrectedTo = corrected
        report.notes.append("stale default engine \(preferred) cleared to \(corrected)")
    }

    // MARK: - (e) Auto-enhance must have a valid AI provider (spec §5.5)

    private func reconcileAutoEnhance(_ report: inout ReconciliationReport) {
        guard settings.autoEnhance, currentConfiguration().aiProvider == nil else { return }
        settings.autoEnhance = false
        report.autoEnhanceDisabled = true
        report.notes.append("auto-enhance disabled: no valid AI provider")
    }

    /// Build the current configuration snapshot from settings + (already-reconciled)
    /// Keychain flags + validity markers. Centralized in `SettingsStore` so every
    /// resolution path agrees (spec §5.5/§6.1).
    private func currentConfiguration() -> ConfiguredEngines {
        settings.configuredEngines
    }
}
