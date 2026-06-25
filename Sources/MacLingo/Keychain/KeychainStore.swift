import Foundation
import Security

/// Which secret a Keychain operation targets. The raw value is the Keychain
/// account; the service is shared (``KeychainStore/service``).
enum KeychainKey: String, CaseIterable, Sendable {
    case aiProvider = "ai-provider"
    case googleCloud = "google-cloud"
}

/// Abstraction over secret storage so `StateReconciler` and tests don't depend on
/// the live Keychain. Conformers must **never** log key material (spec §9).
protocol KeychainStoring: Sendable {
    func hasKey(_ key: KeychainKey) -> Bool
    func read(_ key: KeychainKey) throws -> String?
    func store(_ value: String, for key: KeychainKey) throws
    func delete(_ key: KeychainKey) throws
}

/// Keychain-layer errors. Carries only the `OSStatus`, **never** the secret.
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

/// API keys live **only** in the macOS Keychain (spec §9). `Defaults` stores only
/// a `hasKey(...)` boolean. Values are never logged or included in diagnostics.
struct KeychainStore: KeychainStoring {

    /// Keychain service identifier; namespaced to the app.
    static let service = "com.sharewis.maclingo"

    private let service: String

    init(service: String = KeychainStore.service) {
        self.service = service
    }

    func hasKey(_ key: KeychainKey) -> Bool {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func read(_ key: KeychainKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.dataEncodingFailed
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func store(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Update existing item if present, otherwise add.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func delete(_ key: KeychainKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
