import Foundation

@testable import MacLingo

/// In-memory Keychain double. Immutable presence set keeps it `Sendable`.
struct MockKeychain: KeychainStoring {
    var present: Set<KeychainKey> = []

    func hasKey(_ key: KeychainKey) -> Bool { present.contains(key) }
    func read(_ key: KeychainKey) throws -> String? { nil }
    func store(_ value: String, for key: KeychainKey) throws {}
    func delete(_ key: KeychainKey) throws {}
}

@MainActor
final class MockHotkey: HotkeyRegistering {
    var reregisterCount = 0
    var errorToThrow: Error?

    func reregister() throws {
        reregisterCount += 1
        if let errorToThrow { throw errorToThrow }
    }
}

@MainActor
final class MockLoginItem: LoginItemControlling {
    private(set) var enabled: Bool
    var setError: Error?
    private(set) var setCalls: [Bool] = []

    init(enabled: Bool) { self.enabled = enabled }

    func isEnabled() -> Bool { enabled }

    func setEnabled(_ newValue: Bool) throws {
        if let setError { throw setError }
        setCalls.append(newValue)
        enabled = newValue
    }
}

enum TestError: Error { case forced }

/// An isolated settings environment for a single test.
@MainActor
struct IsolatedSettingsEnv {
    let store: SettingsStore
    let suite: UserDefaults
    let suiteName: String
    let backupDir: URL
}

/// Make an isolated `SettingsStore` over a throwaway `UserDefaults` suite and a
/// temp backup directory, so tests never touch `.standard` or the real app
/// support directory.
@MainActor
func makeIsolatedStore(function: String = #function) -> IsolatedSettingsEnv {
    let suiteName = "com.sharewis.maclingo.tests.\(abs(function.hashValue))"
    let suite = UserDefaults(suiteName: suiteName) ?? .standard
    suite.removePersistentDomain(forName: suiteName)
    let backupDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("maclingo-tests-\(UUID().uuidString)", isDirectory: true)
    let store = SettingsStore(defaults: suite, backupDirectory: backupDir)
    return IsolatedSettingsEnv(store: store, suite: suite, suiteName: suiteName, backupDir: backupDir)
}
