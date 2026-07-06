import Foundation
import Security

/// Thin wrapper over the Security framework for storing per-account secrets
/// (currently just the Anthropic API key). Items are scoped under a single
/// service identifier so a future "Forget all keys" action can wipe them
/// in one query.
///
/// We deliberately don't use UserDefaults for keys — those are world-readable
/// inside the app sandbox AND survive in plaintext in Time Machine backups.
/// Keychain items are encrypted at rest by the OS and require unlock to read.
enum KeychainHelper {
    /// Service identifier — appears in Keychain Access.app under this name.
    /// Stable so users can recognise/purge it manually if they want to.
    private static let service = "club.helixtrading.app"

    /// Logical names for each secret we store. Keep this enum in sync with
    /// the actual call sites — typo'd raw strings would silently miss
    /// existing entries and look like a "key not set" state.
    enum Key: String {
        case anthropicAPIKey      = "anthropic.api_key"
        case opencodeAPIKey       = "opencode.api_key"
        case opencodeServerPass   = "opencode.server_password"
        case socks5Password       = "socks5.password" // reserved for future
        case backendPassword      = "backend.password"
    }

    // MARK: - Read

    /// Returns the stored secret or nil if no entry exists. Errors other
    /// than `errSecItemNotFound` are folded into nil — they all mean "we
    /// can't load the key" which the UI handles uniformly.
    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess,
              let data = ref as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - Write

    /// Insert or update the secret. Empty strings delete the entry —
    /// callers can use this to "forget" a key without a separate API.
    @discardableResult
    static func set(_ key: Key, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(key)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // AfterFirstUnlock suppresses the repeated Keychain auth
            // prompt that WhenUnlockedThisDeviceOnly triggers on
            // every read.  The item is still device-only and
            // encrypted at rest — it just doesn't re-prompt after
            // the user has unlocked their Mac once.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try update first; if the item doesn't exist, insert.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
