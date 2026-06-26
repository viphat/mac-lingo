import Foundation

/// Outcome of launch-time schema migration (spec §5.5, §10).
enum SettingsMigrationOutcome: Equatable, Sendable {
    case upToDate
    case migrated(from: Int, to: Int)
    /// The store was corrupt or a migration threw: it was backed up and reset to
    /// safe defaults. `backupURL` is the timestamped backup if one was written.
    case resetToDefaults(backupURL: URL?)
}

/// Defaults-backed *desired* state (spec §5.5). The persisted store holds
/// preferences only; **secrets live in the Keychain** — this store keeps just a
/// `hasKey(...)` boolean per provider, never the key material.
///
/// Persistence is over an injected `UserDefaults` suite so the migration and
/// fail-safe logic is unit-testable in isolation from `.standard`.
@MainActor
final class SettingsStore: ObservableObject {

    /// Current settings schema version. Bump when adding a migration.
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults
    private let backupDirectory: URL

    /// Set when the most recent launch had to reset a corrupt/unmigratable store
    /// (surfaced to the user as an actionable notice — spec §5.5).
    private(set) var didResetDueToCorruption = false

    init(defaults: UserDefaults = .standard, backupDirectory: URL? = nil) {
        self.defaults = defaults
        self.backupDirectory = backupDirectory ?? Self.defaultBackupDirectory
    }

    // MARK: - Keys

    private enum Key {
        static let schemaVersion = "settingsSchemaVersion"
        static let targetLanguage = "targetLanguage"
        static let defaultEngine = "defaultEngine"
        static let captureMethod = "captureMethod"
        static let appearance = "appearance"
        static let googleCloudEnabled = "googleCloudEnabled"
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        static let autoEnhance = "autoEnhance"
        static let paidConfirmThreshold = "paidConfirmThreshold"
        static let autoSpendLimit = "autoSpendLimit"
        static let launchAtLogin = "launchAtLogin"
        static let hasKeyProvider = "hasKeyProvider"
        static let hasKeyCloud = "hasKeyCloud"
        static let aiKeyInvalid = "aiKeyInvalid"
        static let cloudKeyInvalid = "cloudKeyInvalid"
        static let providerConfigRevision = "providerConfigRevision"

        /// Every key this store owns — used for corruption backup and reset so we
        /// never touch unrelated keys in a shared suite.
        static let all: [String] = [
            schemaVersion, targetLanguage, defaultEngine, captureMethod, appearance,
            googleCloudEnabled, aiProvider, aiModel, autoEnhance, paidConfirmThreshold,
            autoSpendLimit, launchAtLogin, hasKeyProvider, hasKeyCloud, aiKeyInvalid,
            cloudKeyInvalid, providerConfigRevision,
        ]
    }

    // MARK: - Preferences (spec §7)

    var targetLanguage: TargetLanguage {
        get { decode(Key.targetLanguage) ?? .en }
        set { encode(Key.targetLanguage, newValue) }
    }

    var defaultEngine: DefaultEngine {
        get { decode(Key.defaultEngine) ?? .googleFree }
        set { encode(Key.defaultEngine, newValue) }
    }

    var captureMethod: CaptureMethod {
        get { decode(Key.captureMethod) ?? .dual }
        set { encode(Key.captureMethod, newValue) }
    }

    var appearance: AppearanceMode {
        get { decode(Key.appearance) ?? .system }
        set { encode(Key.appearance, newValue) }
    }

    var googleCloudEnabled: Bool {
        get { defaults.bool(forKey: Key.googleCloudEnabled) }
        set { write(Key.googleCloudEnabled, newValue) }
    }

    /// Selected AI provider, or `nil` if none configured.
    var aiProvider: AIProvider? {
        get { decode(Key.aiProvider) }
        set {
            objectWillChange.send()
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.aiProvider)
            } else {
                defaults.removeObject(forKey: Key.aiProvider)
            }
        }
    }

    /// AI model id. Falls back to the selected provider's default model. Editable
    /// config, not a hardcoded constant (CLAUDE.md).
    var aiModel: String {
        get { defaults.string(forKey: Key.aiModel) ?? aiProvider?.defaultModel ?? "" }
        set { write(Key.aiModel, newValue) }
    }

    var autoEnhance: Bool {
        get { defaults.bool(forKey: Key.autoEnhance) }
        set { write(Key.autoEnhance, newValue) }
    }

    /// Paid-translation confirmation threshold in source characters (spec §6.5).
    var paidConfirmThreshold: Int {
        get { defaults.object(forKey: Key.paidConfirmThreshold) as? Int ?? 4_000 }
        set { write(Key.paidConfirmThreshold, newValue) }
    }

    /// Auto-spend limit in characters; `0` means always confirm over threshold
    /// (spec §6.5).
    var autoSpendLimit: Int {
        get { defaults.object(forKey: Key.autoSpendLimit) as? Int ?? 0 }
        set { write(Key.autoSpendLimit, newValue) }
    }

    /// Desired launch-at-login state. **Persist only via `applyAtomic`** after the
    /// `SMAppService` op succeeds (spec §5.5) — never set this directly from the UI.
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { write(Key.launchAtLogin, newValue) }
    }

    /// Whether an AI provider key is believed present (mirrors Keychain; the
    /// Keychain is the source of truth and reconciliation re-derives this).
    var hasKeyProvider: Bool {
        get { defaults.bool(forKey: Key.hasKeyProvider) }
        set { write(Key.hasKeyProvider, newValue) }
    }

    var hasKeyCloud: Bool {
        get { defaults.bool(forKey: Key.hasKeyCloud) }
        set { write(Key.hasKeyCloud, newValue) }
    }

    /// **Present but invalid** marker for the AI key (spec §5.5 "presence is not
    /// validity"): set when Validate fails or a runtime 401/403 rejects the key, so
    /// the provider is treated as unconfigured without deleting the user's key.
    /// Cleared when a new key is stored or Validate succeeds.
    var aiKeyInvalid: Bool {
        get { defaults.bool(forKey: Key.aiKeyInvalid) }
        set { write(Key.aiKeyInvalid, newValue) }
    }

    var cloudKeyInvalid: Bool {
        get { defaults.bool(forKey: Key.cloudKeyInvalid) }
        set { write(Key.cloudKeyInvalid, newValue) }
    }

    /// The current configured-engines snapshot (spec §5.5/§6.1) — the **single**
    /// place "configured" is computed so launch reconciliation, live reconciliation,
    /// trigger-time resolution, and the settings selector all agree. "Configured"
    /// means present **and** not marked invalid; Google Free is always available
    /// until the Phase 7 kill switch.
    var configuredEngines: ConfiguredEngines {
        ConfiguredEngines(
            googleFreeAvailable: true,
            googleCloudConfigured: googleCloudEnabled && hasKeyCloud && !cloudKeyInvalid,
            aiProvider: (hasKeyProvider && !aiKeyInvalid) ? aiProvider : nil)
    }

    /// Monotonic provider-config revision (spec §5.1, §5.5). Part of the `CacheKey`:
    /// any provider/model/key change (or a Free-endpoint switch) bumps it so
    /// dependent cache entries become unreachable. Persisted so a relaunch never
    /// reuses a revision an earlier session may have cached against.
    var providerConfigRevision: UInt64 {
        get { UInt64(bitPattern: Int64(defaults.integer(forKey: Key.providerConfigRevision))) }
        set { write(Key.providerConfigRevision, Int64(bitPattern: newValue)) }
    }

    /// Bump and return the new provider-config revision (spec §5.5 live reconcile).
    @discardableResult
    func bumpProviderConfigRevision() -> UInt64 {
        let next = providerConfigRevision &+ 1
        providerConfigRevision = next
        return next
    }

    // MARK: - Atomic system-state writes (spec §5.5)

    /// Apply a system side effect **first**; persist the new value **only if it
    /// succeeds**. On failure the persisted value is untouched and the error
    /// rethrows. No optimistic persistence.
    func applyAtomic<V>(
        _ newValue: V,
        system: (V) throws -> Void,
        persist: (V) -> Void
    ) throws {
        try system(newValue)
        persist(newValue)
    }

    // MARK: - Schema migration & fail-safe (spec §5.5, §10)

    /// Run at launch. Migrates an older store forward; on a corrupt/unreadable
    /// store or a throwing migration, backs up the bad data, resets to safe
    /// defaults, and reports it — **never hard-fails launch**.
    func migrateIfNeeded() -> SettingsMigrationOutcome {
        let stored = defaults.object(forKey: Key.schemaVersion)

        // Fresh install (no version yet): stamp current and validate nothing else.
        guard let stored else {
            defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
            return .upToDate
        }

        // A non-integer version is corruption.
        guard let version = stored as? Int else {
            return reset()
        }

        if version == Self.currentSchemaVersion {
            return validateOrReset(successOutcome: .upToDate)
        }

        // Newer store from a future build: ignore unknown keys, do not downgrade
        // (forward/backward tolerant — spec §10).
        if version > Self.currentSchemaVersion {
            return .upToDate
        }

        // Older store: migrate forward, fail-safe on any error.
        do {
            try runMigrations(from: version, to: Self.currentSchemaVersion)
            defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
            return .migrated(from: version, to: Self.currentSchemaVersion)
        } catch {
            return reset()
        }
    }

    /// Additive, ordered migrations. Each step must be forward/backward tolerant
    /// and must throw `SettingsError.migrationFailed` on unrecoverable input.
    private func runMigrations(from: Int, to: Int) throws {
        var version = from
        while version < to {
            switch version {
            // case 0: try migrateV0toV1()  // first real migration lands here
            default:
                // No migration registered for this step → treat as unrecoverable
                // so the fail-safe path resets rather than silently skipping.
                throw SettingsError.migrationFailed(fromVersion: version)
            }
        }
    }

    /// Validate that the owned keys decode to their expected types; reset if not.
    private func validateOrReset(successOutcome: SettingsMigrationOutcome) -> SettingsMigrationOutcome {
        if hasUndecodableValue(Key.targetLanguage, as: TargetLanguage.self) { return reset() }
        if hasUndecodableValue(Key.defaultEngine, as: DefaultEngine.self) { return reset() }
        return successOutcome
    }

    /// True when a stored string value for `key` no longer decodes to `T` (a
    /// corruption signal). Absent values are fine — they fall back to defaults.
    private func hasUndecodableValue<T: RawRepresentable>(
        _ key: String, as type: T.Type
    ) -> Bool where T.RawValue == String {
        guard let raw = defaults.string(forKey: key) else { return false }
        return T(rawValue: raw) == nil
    }

    /// Back up the owned keys to a timestamped file, clear them, and stamp the
    /// current schema version. Keychain is untouched (spec §5.5).
    private func reset() -> SettingsMigrationOutcome {
        let backupURL = writeBackup()
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
        didResetDueToCorruption = true
        return .resetToDefaults(backupURL: backupURL)
    }

    private func writeBackup() -> URL? {
        var snapshot: [String: Any] = [:]
        for key in Key.all where defaults.object(forKey: key) != nil {
            snapshot[key] = defaults.object(forKey: key)
        }
        guard !snapshot.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp =
            formatter
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = backupDirectory.appendingPathComponent("settings-backup-\(timestamp).plist")
        do {
            try FileManager.default.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: snapshot, format: .xml, options: 0)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Low-level helpers

    private func decode<T: RawRepresentable>(_ key: String) -> T? where T.RawValue == String {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    private func encode<T: RawRepresentable>(_ key: String, _ value: T) where T.RawValue == String {
        write(key, value.rawValue)
    }

    private func write(_ key: String, _ value: Any) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    private static var defaultBackupDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacLingo", isDirectory: true)
    }
}

/// Settings-layer errors (spec §5.5).
enum SettingsError: Error, Equatable {
    case migrationFailed(fromVersion: Int)
}
