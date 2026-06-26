import Foundation

/// Persists the ``RemoteConfigState`` (spec §6.1). JSON-encoded into an injected
/// `UserDefaults` suite so the lifecycle is testable in isolation. The state holds
/// no secrets — only trust bookkeeping (epoch floor, version, sticky-disable flag,
/// selected endpoint, clock high-water mark).
final class RemoteConfigStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "remoteConfigState") {
        self.defaults = defaults
        self.key = key
    }

    /// Load the persisted state, or `nil` on a fresh install / unreadable blob.
    /// A corrupt blob is treated as absent (fail-safe — the caller seeds `initial`).
    func load() -> RemoteConfigState? {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(RemoteConfigState.self, from: data)
        }
    }

    func save(_ state: RemoteConfigState) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(state) else { return }
            defaults.set(data, forKey: key)
        }
    }
}
