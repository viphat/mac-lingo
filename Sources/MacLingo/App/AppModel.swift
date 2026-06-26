import OSLog
import SwiftUI

/// Outcome of a Validate action (spec §5.5/§7).
enum KeyValidationResult: Equatable, Sendable {
    case valid
    /// The provider rejected the key (HTTP 401/403) — marks it unconfigured.
    case invalidKey
    /// Inconclusive (network or other error) — the key is not marked invalid.
    case failed(String)
}

/// Owns the shared, long-lived collaborators and runs launch bootstrap. Injected
/// into SwiftUI views as an `EnvironmentObject`.
@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let permissions: PermissionsCoordinator
    let keychain: KeychainStoring
    let hotkey: HotkeyManager
    let loginItem: LoginItemController
    let reconciler: StateReconciler

    /// Live engine factory (reads the active AI key/model); shared with the panels.
    private let registry: TranslationServiceRegistry
    private let presenter: ModalPresenter

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
        let registry = TranslationServiceRegistry()
        let presenter = ModalPresenter(services: registry)
        self.registry = registry
        self.presenter = presenter
        self.coordinator = TranslationCoordinator(
            capturer: SelectionCapturer(), settings: settings, presenter: presenter)

        // A runtime 401/403 from a paid engine marks it unconfigured and triggers
        // live reconciliation (spec §5.5).
        presenter.onProviderUnauthorized = { [weak self] engine in
            self?.handleProviderUnauthorized(engine)
        }
    }

    /// Run once at launch: migrate settings (fail-safe), reconcile system/provider
    /// state, load the active AI runtime config, attach the hotkey, read permissions.
    func bootstrap() {
        migrationOutcome = settings.migrateIfNeeded()
        if case .resetToDefaults(let backupURL) = migrationOutcome {
            log.error("settings were reset to defaults; backup: \(backupURL?.path ?? "none", privacy: .public)")
        }
        reconciler.reconcileAtLaunch()
        refreshAIRuntimeConfig()
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

    // MARK: - AI key / provider management (spec §5.5, §6.4, §9)

    /// Store a new AI key in the Keychain (never Defaults) and live-reconcile. A new
    /// key clears any "invalid" marker.
    func setAIKey(_ key: String, provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.aiProvider = provider
        do {
            try keychain.store(trimmed, for: .aiProvider)
            settings.hasKeyProvider = true
            settings.aiKeyInvalid = false
        } catch {
            log.error("storing AI key failed: \(String(describing: error), privacy: .public)")
        }
        reconcileProvidersLive()
    }

    /// Remove the AI key from the Keychain and live-reconcile (default falls back).
    func removeAIKey() {
        try? keychain.delete(.aiProvider)
        settings.hasKeyProvider = false
        settings.aiKeyInvalid = false
        reconcileProvidersLive()
    }

    /// Any provider-setting change (provider switch, model edit) live-reconciles.
    func onProviderChanged() {
        reconcileProvidersLive()
    }

    func setAIModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.aiModel = trimmed.isEmpty ? (settings.aiProvider?.defaultModel ?? "") : trimmed
        reconcileProvidersLive()
    }

    /// Validate the stored key with a minimal request (spec §7). A 401/403 marks the
    /// provider unconfigured; a network error is inconclusive and does not.
    func validateAIKey() async -> KeyValidationResult {
        guard let provider = settings.aiProvider,
            let key = try? keychain.read(.aiProvider), !key.isEmpty
        else { return .failed("no key stored") }

        let service: OpenAICompatibleProvider =
            provider == .openAI
            ? .openAI(model: settings.aiModel, apiKey: key)
            : .deepSeek(model: settings.aiModel, apiKey: key)
        let request = TranslationRequest(
            operationID: 0,
            selection: SelectionSnapshot(id: 0, source: FormattedText(plainText: "hello")),
            engine: provider.engineID, target: .en)

        do {
            _ = try await service.translate(request)
            settings.aiKeyInvalid = false
            reconcileProvidersLive()
            return .valid
        } catch TranslationError.unauthorized {
            settings.aiKeyInvalid = true
            reconcileProvidersLive()
            return .invalidKey
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func handleProviderUnauthorized(_ engine: EngineID) {
        guard engine.isAI else { return }  // Cloud handled in Phase 6
        guard !settings.aiKeyInvalid else { return }
        log.notice("AI provider returned 401/403; marking unconfigured")
        settings.aiKeyInvalid = true
        reconcileProvidersLive()
    }

    /// Apply provider changes atomically (spec §5.5): repair desired state, refresh
    /// the live AI config, bump `providerConfigRevision` (invalidating dependent
    /// cache entries), and fan out to live panels.
    private func reconcileProvidersLive() {
        reconciler.reconcileProvidersLive()
        refreshAIRuntimeConfig()
        let revision = settings.bumpProviderConfigRevision()
        let configured = settings.configuredEngines
        let available = TranslationCoordinator.availableEngines(configured)
        presenter.reconcileProviders(revision: revision, availableEngines: available) { _ in
            EngineResolver.resolve(preferred: settings.defaultEngine, available: configured)
        }
    }

    /// Push the current AI provider/model/key into the service registry, or clear it
    /// when no valid AI provider is configured.
    private func refreshAIRuntimeConfig() {
        guard let provider = settings.aiProvider, settings.hasKeyProvider, !settings.aiKeyInvalid,
            let key = try? keychain.read(.aiProvider), !key.isEmpty
        else {
            registry.updateAIConfig(nil)
            return
        }
        registry.updateAIConfig(
            AIRuntimeConfig(engineID: provider.engineID, model: settings.aiModel, apiKey: key))
    }
}
