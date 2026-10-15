import Foundation
import Security

/// Stores the user's own Anthropic API key in the macOS Keychain — never
/// in `UserDefaults`/plist (those are plain files on disk) and never
/// bundled with the app (this app ships with no API key of its own; AI
/// naming is entirely opt-in and requires the user's own key and their
/// own Anthropic billing).
enum APIKeyStore {
    private static let service = "app.photocurator.anthropic-api-key"
    private static let account = "default"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add rather than update: simpler than building the
        // right SecItemUpdate attribute dictionary, and this is a rare,
        // user-initiated action (entering a key in Settings), not a hot
        // path worth optimising.
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
