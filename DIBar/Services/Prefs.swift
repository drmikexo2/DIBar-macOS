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

    /// One-time defaults migration (v2): new installs get all menu-bar
    /// components and global shortcuts ON; existing installs keep their
    /// previous effective defaults by pinning explicit "0"s for any key they
    /// never touched. Must run before AppState is created — its stored
    /// properties read these keys at init.
    static func migrateDefaultsV2() {
        guard read(key: "defaults_v2") == nil else { return }
        defer { save(key: "defaults_v2", value: "1") }

        // An existing install has at least one long-standing pref present.
        let existingInstall = read(key: "listen_key") != nil
            || read(key: "selected_network") != nil
            || read(key: "recent_stations") != nil
        guard existingInstall else { return }

        for key in ["menubar_show_site", "menubar_show_station",
                    "menubar_show_artist", "menubar_show_song",
                    "global_hotkeys"] where read(key: key) == nil {
            save(key: key, value: "0")
        }
    }
}
