import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

/// Session lifecycle: startup bootstrap, login, logout.
extension AppState {
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Migrate legacy last-station keys (old name "favorite_station_id" was
        // misleading — it stores the last played station, not a favorite)
        if let oldStation = Prefs.rawRead("favorite_station_id") {
            Prefs.set(oldStation, for: .lastStationId, network: .di)
            Prefs.rawDelete("favorite_station_id")
            log.info("bootstrap: migrated favorite_station_id to last_station_id.di")
        }
        for network in Network.allCases {
            if let oldStation = Prefs.rawRead("favorite_station_id.\(network.rawValue)") {
                Prefs.set(oldStation, for: .lastStationId, network: network)
                Prefs.rawDelete("favorite_station_id.\(network.rawValue)")
            }
        }

        // Migrate the old single "show track in menu bar" toggle to components
        if Prefs.rawRead("show_track_in_menu_bar") == "1" {
            menuBarShowArtist = true
            menuBarShowSong = true
        }
        Prefs.rawDelete("show_track_in_menu_bar")

        // ListenBrainz support removed — drop stored credentials
        Prefs.rawDelete("listenbrainz_token")
        Prefs.rawDelete("listenbrainz_username")

        recentStationsStore.load()

        // Restore last selected network
        if let raw = Prefs.string(.selectedNetwork), let net = Network(rawValue: raw) {
            selectedNetwork = net
            log.info("bootstrap: restored network=\(net.rawValue)")
        }

        log.info("bootstrap: checking stored credentials")
        if let key = Prefs.string(.listenKey) {
            listenKey = key
            apiKey = Prefs.string(.apiKey)
            if let id = Prefs.int(.memberId) {
                memberId = id
                log.info("bootstrap: found stored memberId=\(id)")
            } else {
                log.warning("bootstrap: no stored member_id found")
            }
            log.info("bootstrap: apiKey=\(self.apiKey != nil ? "present" : "nil")")
            isLoggedIn = true
            if apiKey != nil {
                async let channelsLoad: Void = loadChannels(for: selectedNetwork, restoreStation: true)
                async let membershipLoad: Void = loadMembership()
                _ = await (channelsLoad, membershipLoad)
            } else {
                await loadChannels(for: selectedNetwork, restoreStation: true)
            }
        } else {
            log.info("bootstrap: no stored listen_key")
        }
    }

    func login(email: String, password: String) async {
        errorMessage = nil
        isLoading = true

        do {
            let response = try await DIClient.authenticate(email: email, password: password)
            Prefs.set(response.listenKey, for: .listenKey)
            if let ak = response.apiKey {
                Prefs.set(ak, for: .apiKey)
                log.info("login: apiKey saved")
            } else {
                log.warning("login: apiKey is nil in auth response")
            }
            if let mid = response.resolvedMemberId {
                Prefs.set(mid, for: .memberId)
                memberId = mid
                log.info("login: memberId=\(mid)")
            } else {
                log.warning("login: resolvedMemberId is nil! Auth response had no member ID.")
            }
            listenKey = response.listenKey
            apiKey = response.apiKey
            subscriptions = response.subscriptions ?? []
            isLoggedIn = true
            await loadChannels(for: selectedNetwork)
        } catch {
            errorMessage = error.localizedDescription
            log.error("login error: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func logout() {
        audioPlayer.stop()
        Prefs.set(nil, for: .listenKey)
        Prefs.set(nil, for: .apiKey)
        Prefs.set(nil, for: .memberId)
        Prefs.set(nil, for: .selectedNetwork)
        recentStationsStore.clear()
        for network in Network.allCases {
            Prefs.set(nil, for: .lastStationId, network: network)
            Prefs.set(nil, for: .localFavAdded, network: network)
            Prefs.set(nil, for: .localFavRemoved, network: network)
        }
        listenKey = nil
        apiKey = nil
        memberId = nil
        subscriptions = []
        isLoggedIn = false
        networkDataCache = [:]
        sessionUnfavorited = [:]
        playingNetwork = nil
        selectedNetwork = .di
        searchText = ""
        errorMessage = nil
    }
}
