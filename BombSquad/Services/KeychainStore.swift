import Foundation
import Security

/// Minimal Keychain wrapper for per-provider API keys.
/// Keys never touch disk in plain text or the repository.
enum KeychainStore {
    private static let service = "com.universal-io.mac"
    private static let legacyServices = [
        "com.heywatchme.bombsquad",
        "com.matsumotokaya.justamoment",
        "com.matsumotokaya.bombsquad",
    ]

    /// Stores or replaces the API key for `account`. Empty string deletes it.
    static func saveAPIKey(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(account: account)
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Returns the stored API key for `account`, or nil when none is set.
    static func apiKey(account: String) -> String? {
        if let value = apiKey(account: account, service: service) {
            return value
        }

        for legacyService in legacyServices {
            if let value = apiKey(account: account, service: legacyService) {
                saveAPIKey(value, account: account)
                return value
            }
        }

        return nil
    }

    private static func apiKey(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    static func deleteAPIKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
