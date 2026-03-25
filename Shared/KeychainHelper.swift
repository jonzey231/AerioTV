import Foundation
import Security

// MARK: - Keychain Helper
// Thread-safe static utility for storing small secrets (passwords, API keys) in the iOS Keychain.
// Keys are namespaced under the app's bundle identifier to avoid collisions.
// Pass `synchronizable: true` to sync credentials via iCloud Keychain across devices.

enum KeychainHelper {

    private static let service: String = {
        Bundle.main.bundleIdentifier ?? "com.aerio.app"
    }()

    // MARK: - Save

    /// Saves `value` under `key`. Overwrites any existing entry.
    /// When `synchronizable` is true, the credential syncs via iCloud Keychain.
    @discardableResult
    static func save(_ value: String, for key: String, synchronizable: Bool = false) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first so SecItemAdd always succeeds.
        delete(key, synchronizable: synchronizable)

        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData:   data
        ]
        if synchronizable {
            query[kSecAttrSynchronizable] = true
        }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Load

    /// Returns the stored string for `key`, or `nil` if none exists.
    /// When `synchronizable` is true, searches for iCloud Keychain items.
    static func load(key: String, synchronizable: Bool = false) -> String? {
        var query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        if synchronizable {
            query[kSecAttrSynchronizable] = true
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Delete

    /// Deletes the entry for `key`. No-op if it does not exist.
    /// When `synchronizable` is true, deletes the iCloud Keychain entry.
    @discardableResult
    static func delete(_ key: String, synchronizable: Bool = false) -> Bool {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        if synchronizable {
            query[kSecAttrSynchronizable] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Migrate to Synchronizable

    /// Copies a local-only credential to iCloud Keychain (if it exists and isn't already synced).
    @discardableResult
    static func migrateToSynchronizable(key: String) -> Bool {
        // Read from local keychain
        guard let value = load(key: key, synchronizable: false) else { return false }
        // Check if already in iCloud keychain
        if load(key: key, synchronizable: true) != nil { return true }
        // Save to iCloud keychain
        return save(value, for: key, synchronizable: true)
    }
}
