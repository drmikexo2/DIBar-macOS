import Foundation

/// App settings and session tokens, stored in UserDefaults.
///
/// Booleans are stored as "1"/"0" strings (the historical format). Keys live
/// in the `Key`/`NetworkKey` registries so a typo can't silently orphan a
/// setting; only the defaults migration touches raw legacy key strings.
enum Prefs {
    private static let prefix = "com.dibar."

    /// Every single-valued key the app stores.
    enum Key: String {
        case defaultsV2 = "defaults_v2"
        case listenKey = "listen_key"
        case apiKey = "api_key"
        case memberId = "member_id"
        case accountEmail = "account_email"
        case selectedNetwork = "selected_network"
        case allNetworksSelected = "all_networks_selected"
        case recentStations = "recent_stations"
        case quality
        case notifyTrackChanges = "notify_track_changes"
        case notifyChannelSwitch = "notify_channel_switch"
        case outputDeviceUID = "output_device_uid"
        case globalHotkeys = "global_hotkeys"
        case sleepTimerQuits = "sleep_timer_quits"
        case menuBarShowPlayState = "menubar_show_playstate"
        case menuBarShowSite = "menubar_show_site"
        case menuBarShowStation = "menubar_show_station"
        case menuBarShowArtist = "menubar_show_artist"
        case menuBarShowSong = "menubar_show_song"
        case allStationsExpanded = "all_stations_expanded"
        case recentStationsExpanded = "recent_stations_expanded"
        case sleepTimerCustomMinutes = "sleep_timer_custom_minutes"
        case lastFMSessionKey = "lastfm_session_key"
        case lastFMUsername = "lastfm_username"
        case pendingUpdateVersion = "pending_update_version"
        case pendingUpdateBuild = "pending_update_build"
        case pendingUpdateAttempts = "pending_update_attempts"
    }

    /// Keys stored once per network, as "<key>.<network>".
    enum NetworkKey: String {
        case lastStationId = "last_station_id"
        case localFavAdded = "local_fav_added"
        case localFavRemoved = "local_fav_removed"
    }

    // MARK: - Typed accessors

    static func string(_ key: Key) -> String? {
        read(key: key.rawValue)
    }

    static func set(_ value: String?, for key: Key) {
        if let value {
            save(key: key.rawValue, value: value)
        } else {
            delete(key: key.rawValue)
        }
    }

    /// Booleans store as "1"/"0"; a missing key yields `default`.
    static func bool(_ key: Key, default defaultValue: Bool) -> Bool {
        guard let raw = read(key: key.rawValue) else { return defaultValue }
        return raw != "0"
    }

    static func set(_ value: Bool, for key: Key) {
        save(key: key.rawValue, value: value ? "1" : "0")
    }

    static func int(_ key: Key) -> Int? {
        read(key: key.rawValue).flatMap(Int.init)
    }

    static func set(_ value: Int, for key: Key) {
        save(key: key.rawValue, value: String(value))
    }

    // MARK: - Per-network accessors

    static func string(_ key: NetworkKey, network: Network) -> String? {
        read(key: "\(key.rawValue).\(network.rawValue)")
    }

    static func set(_ value: String?, for key: NetworkKey, network: Network) {
        if let value {
            save(key: "\(key.rawValue).\(network.rawValue)", value: value)
        } else {
            delete(key: "\(key.rawValue).\(network.rawValue)")
        }
    }

    static func int(_ key: NetworkKey, network: Network) -> Int? {
        string(key, network: network).flatMap(Int.init)
    }

    static func set(_ value: Int, for key: NetworkKey, network: Network) {
        set(String(value), for: key, network: network)
    }

    /// Int sets store comma-joined ("12,34"); an empty set stores "".
    static func intSet(_ key: NetworkKey, network: Network) -> Set<Int> {
        Set((string(key, network: network) ?? "")
            .split(separator: ",")
            .compactMap { Int($0) })
    }

    static func set(_ value: Set<Int>, for key: NetworkKey, network: Network) {
        set(value.map(String.init).joined(separator: ","), for: key, network: network)
    }

    // MARK: - Raw storage

    private static func save(key: String, value: String) {
        migrateIfNeeded()
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    private static func read(key: String) -> String? {
        migrateIfNeeded()
        return UserDefaults.standard.string(forKey: prefix + key)
    }

    private static func delete(key: String) {
        migrateIfNeeded()
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    // Migration paths deal in legacy keys that never made it into the
    // registries — they use the raw string API on purpose.
    static func rawRead(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func rawSave(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func rawDelete(_ key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    // MARK: - Migration

    private static var migrated = false

    /// One-time defaults migration (v2): new installs get all menu-bar
    /// components and global shortcuts ON; existing installs keep their
    /// previous effective defaults by pinning explicit "0"s for any key they
    /// never touched. Runs lazily on first access, so no caller ordering can
    /// observe pre-migration values.
    private static func migrateIfNeeded() {
        guard !migrated else { return }
        migrated = true

        guard rawRead(Key.defaultsV2.rawValue) == nil else { return }
        defer { rawSave(Key.defaultsV2.rawValue, "1") }

        // An existing install has at least one long-standing pref present.
        let existingInstall = rawRead(Key.listenKey.rawValue) != nil
            || rawRead(Key.selectedNetwork.rawValue) != nil
            || rawRead(Key.recentStations.rawValue) != nil
        guard existingInstall else { return }

        for key in [Key.menuBarShowSite, .menuBarShowStation,
                    .menuBarShowArtist, .menuBarShowSong,
                    .globalHotkeys] where rawRead(key.rawValue) == nil {
            rawSave(key.rawValue, "0")
        }
    }
}
