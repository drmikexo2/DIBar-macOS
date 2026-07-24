import Foundation
import Security

/// Secrets storage backed by the macOS Keychain (generic passwords under
/// service "com.dibar"). Non-secret preferences belong in Prefs instead.
enum KeychainHelper {
    private static let service = "com.dibar"

    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration of secrets that earlier versions stored in
    /// UserDefaults under "com.dibar.<key>".
    static func migrateFromUserDefaults(keys: [String]) {
        for key in keys {
            let defaultsKey = "com.dibar.\(key)"
            guard let value = UserDefaults.standard.string(forKey: defaultsKey) else { continue }
            save(key: key, value: value)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
