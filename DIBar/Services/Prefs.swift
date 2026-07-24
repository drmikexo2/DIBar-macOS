import Foundation

/// App settings and session tokens, stored in UserDefaults.
enum Prefs {
    private static let prefix = "com.dibar."

    static func save(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func read(key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }
}
