import Foundation
import Security

/// Manages secure storage of API keys in the macOS Keychain.
enum KeychainManager {

    private static let service = "com.fayazahmed.Kaze"

    /// Saves an API key for the given provider to the Keychain.
    /// Overwrites any existing key for the same provider.
    @discardableResult
    static func saveAPIKey(_ key: String, for provider: CloudAIProvider) -> Bool {
        let account = provider.keychainAccount
        guard let data = key.data(using: .utf8) else { return false }

        // Delete any existing item first
        deleteAPIKey(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves the stored API key for the given provider.
    static func getAPIKey(for provider: CloudAIProvider) -> String? {
        let account = provider.keychainAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored API key for the given provider.
    @discardableResult
    static func deleteAPIKey(for provider: CloudAIProvider) -> Bool {
        let account = provider.keychainAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Checks whether an API key is stored for the given provider.
    static func hasAPIKey(for provider: CloudAIProvider) -> Bool {
        getAPIKey(for: provider) != nil
    }
}
