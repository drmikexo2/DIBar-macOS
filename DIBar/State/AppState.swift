import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

struct NetworkData {
    var channels: [Channel] = []
    var favoriteChannelIds: Set<Int> = []
    var isLoaded: Bool = false
    var favoritesLoadFailed: Bool = false
}

@Observable
@MainActor
final class AppState {
    private var didBootstrap = false

    // Auth
    var isLoggedIn: Bool = false
    var listenKey: String?
    var apiKey: String?
    var memberId: Int?

    // Network
    var selectedNetwork: Network = .di
    var playingNetwork: Network?
    private var networkDataCache: [Network: NetworkData] = [:]

    // Search
    var searchText: String = ""

    // Playback
    let audioPlayer = AudioPlayer()

    // Listening history
    let historyRecorder: HistoryRecorder
    var saveListeningHistory: Bool = Prefs.read(key: "save_history") != "0" {
        didSet {
            Prefs.save(key: "save_history", value: saveListeningHistory ? "1" : "0")
            historyRecorder.setEnabled(saveListeningHistory)
        }
    }

    // Settings
    var selectedQuality: StreamQuality = {
        if let raw = Prefs.read(key: "quality"), let q = StreamQuality(rawValue: raw) {
            return q
        }
        return .premiumHigh
    }()
    var subscriptions: [MembershipSubscription] = []

    // UI
    var isLoading: Bool = false
    var errorMessage: String?
    var searchFieldFocused: Bool = false
    var artworkExpanded: Bool = false
    // Menu bar label components. "Site" in the UI, Network in code.
    // Play/pause glyph defaults ON; the text components default OFF.
    var menuBarShowPlayState: Bool = Prefs.read(key: "menubar_show_playstate") != "0" {
        didSet { Prefs.save(key: "menubar_show_playstate", value: menuBarShowPlayState ? "1" : "0") }
    }
    var menuBarShowSite: Bool = Prefs.read(key: "menubar_show_site") == "1" {
        didSet { Prefs.save(key: "menubar_show_site", value: menuBarShowSite ? "1" : "0") }
    }
    var menuBarShowStation: Bool = Prefs.read(key: "menubar_show_station") == "1" {
        didSet { Prefs.save(key: "menubar_show_station", value: menuBarShowStation ? "1" : "0") }
    }
    var menuBarShowArtist: Bool = Prefs.read(key: "menubar_show_artist") == "1" {
        didSet { Prefs.save(key: "menubar_show_artist", value: menuBarShowArtist ? "1" : "0") }
    }
    var menuBarShowSong: Bool = Prefs.read(key: "menubar_show_song") == "1" {
        didSet { Prefs.save(key: "menubar_show_song", value: menuBarShowSong ? "1" : "0") }
    }

    // Favorites sync — flips false on a definitive 404/405 from the write
    // endpoint, after which stars still work but only locally.
    var favoritesSyncAvailable: Bool = true

    // Stations unfavorited this session stay visible in the Favorites section
    // (with an outline star) so they're easy to re-favorite. Resets on relaunch.
    private var sessionUnfavorited: [Network: Set<Int>] = [:]

    // MARK: - Computed

    var channels: [Channel] {
        networkDataCache[selectedNetwork]?.channels ?? []
    }

    var favoriteChannelIds: Set<Int> {
        networkDataCache[selectedNetwork]?.favoriteChannelIds ?? []
    }

    var favoritesLoadFailed: Bool {
        networkDataCache[selectedNetwork]?.favoritesLoadFailed ?? false
    }

    var favoriteChannels: [Channel] {
        let visible = favoriteChannelIds.union(sessionUnfavorited[selectedNetwork] ?? [])
        return channels
            .filter { visible.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredChannels: [Channel] {
        let sorted = channels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var subscriptionURL: URL {
        selectedNetwork.subscriptionURL
    }

    /// Subscription for the selected network, falling back to any active
    /// subscription — in practice one premium subscription streams every
    /// AudioAddict network (verified against the live listen servers).
    var membershipSubscription: MembershipSubscription? {
        subscription(for: selectedNetwork) ?? activeSubscription
    }

    var activeSubscription: MembershipSubscription? {
        subscriptions.first { ($0.status?.lowercased() ?? "") == "active" || $0.trial == true }
    }

    /// True once we have real subscription data to gate against.
    var knowsSubscriptions: Bool { !subscriptions.isEmpty }

    /// "Site · Station" for the menu bar, per the component toggles; nil when
    /// idle or nothing is selected for this line.
    var menuBarLine1: String? {
        guard audioPlayer.isPlaying else { return nil }
        return composedLine1(
            site: audioPlayer.currentNetwork?.displayName,
            station: audioPlayer.currentChannel?.name
        )
    }

    /// "Artist – Song" for the menu bar, per the component toggles.
    var menuBarLine2: String? {
        guard audioPlayer.isPlaying, let track = audioPlayer.currentTrack else { return nil }
        return composedLine2(artist: track.artist, song: track.title)
    }

    /// Preview variants for the settings area: live values while playing,
    /// placeholder examples otherwise. Same joining logic as the real label.
    var menuBarPreviewLine1: String? {
        composedLine1(
            site: audioPlayer.isPlaying ? audioPlayer.currentNetwork?.displayName : "Jazz Radio",
            station: audioPlayer.isPlaying ? audioPlayer.currentChannel?.name : "Ambient"
        )
    }

    var menuBarPreviewLine2: String? {
        if audioPlayer.isPlaying, let track = audioPlayer.currentTrack {
            return composedLine2(artist: track.artist, song: track.title)
        }
        return composedLine2(artist: "Metallica", song: "So What")
    }

    private func composedLine1(site: String?, station: String?) -> String? {
        var parts: [String] = []
        if menuBarShowSite, let site, !site.isEmpty {
            parts.append(site)
        }
        if menuBarShowStation, let station, !station.isEmpty {
            parts.append(station)
        }
        guard !parts.isEmpty else { return nil }
        return Self.truncateForMenuBar(parts.joined(separator: " · "))
    }

    private func composedLine2(artist: String?, song: String?) -> String? {
        var parts: [String] = []
        if menuBarShowArtist, let artist, !artist.isEmpty {
            parts.append(artist)
        }
        if menuBarShowSong, let song, !song.isEmpty, song != "Loading..." {
            parts.append(song)
        }
        guard !parts.isEmpty else { return nil }
        return Self.truncateForMenuBar(parts.joined(separator: " – "))
    }

    private static func truncateForMenuBar(_ text: String) -> String {
        text.count > 35 ? String(text.prefix(34)) + "…" : text
    }

    func subscription(for network: Network) -> MembershipSubscription? {
        subscriptions.first { sub in
            // Older responses may omit network_id; treat those as DI since we authenticate against DI.
            let subNetwork = sub.networkId.flatMap(Network.from(networkId:)) ?? .di
            guard subNetwork == network else { return false }
            let status = sub.status?.lowercased() ?? ""
            return status == "active" || status == "trial" || sub.trial == true
        }
    }

    /// True when a playback failure is plausibly a missing-premium problem:
    /// we know the account's subscriptions and none of them is active.
    var playbackFailureLooksLikeNoPremium: Bool {
        knowsSubscriptions && activeSubscription == nil
    }

    var membershipHeaderLine: String {
        guard let status = membershipSubscription?.status?.capitalized, !status.isEmpty else {
            return "Membership"
        }
        return "Membership (\(status))"
    }

    var membershipDetailLine: String {
        guard let subscription = membershipSubscription else {
            if knowsSubscriptions {
                return "No active subscription — tap to subscribe"
            }
            return "Tap to manage subscription"
        }

        var parts: [String] = []
        if let startedAt = subscription.startedDate {
            parts.append("Started \(Self.readableDateFormatter.string(from: startedAt))")
        }
        if let expiresOn = subscription.expiresOnDate {
            let prefix = (subscription.autoRenew ?? false) ? "Renews" : "Expires"
            parts.append("\(prefix) \(Self.readableDateFormatter.string(from: expiresOn))")
        }
        if parts.isEmpty {
            return "Tap to manage subscription"
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - Lifecycle

    init() {
        historyRecorder = HistoryRecorder(player: audioPlayer)
        historyRecorder.setEnabled(saveListeningHistory)
        historyRecorder.start()
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Migrate legacy last-station keys (old name "favorite_station_id" was
        // misleading — it stores the last played station, not a favorite)
        if let oldStation = Prefs.read(key: "favorite_station_id") {
            Prefs.save(key: "last_station_id.di", value: oldStation)
            Prefs.delete(key: "favorite_station_id")
            log.info("bootstrap: migrated favorite_station_id to last_station_id.di")
        }
        for network in Network.allCases {
            if let oldStation = Prefs.read(key: "favorite_station_id.\(network.rawValue)") {
                Prefs.save(key: "last_station_id.\(network.rawValue)", value: oldStation)
                Prefs.delete(key: "favorite_station_id.\(network.rawValue)")
            }
        }

        // Migrate the old single "show track in menu bar" toggle to components
        if Prefs.read(key: "show_track_in_menu_bar") == "1" {
            menuBarShowArtist = true
            menuBarShowSong = true
        }
        Prefs.delete(key: "show_track_in_menu_bar")

        // Restore last selected network
        if let raw = Prefs.read(key: "selected_network"), let net = Network(rawValue: raw) {
            selectedNetwork = net
            log.info("bootstrap: restored network=\(net.rawValue)")
        }

        log.info("bootstrap: checking stored credentials")
        if let key = Prefs.read(key: "listen_key") {
            listenKey = key
            apiKey = Prefs.read(key: "api_key")
            if let idStr = Prefs.read(key: "member_id"), let id = Int(idStr) {
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
            Prefs.save(key: "listen_key", value: response.listenKey)
            if let ak = response.apiKey {
                Prefs.save(key: "api_key", value: ak)
                log.info("login: apiKey saved")
            } else {
                log.warning("login: apiKey is nil in auth response")
            }
            if let mid = response.resolvedMemberId {
                Prefs.save(key: "member_id", value: String(mid))
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
        Prefs.delete(key: "listen_key")
        Prefs.delete(key: "api_key")
        Prefs.delete(key: "member_id")
        Prefs.delete(key: "selected_network")
        for network in Network.allCases {
            Prefs.delete(key: "last_station_id.\(network.rawValue)")
            Prefs.delete(key: "local_fav_added.\(network.rawValue)")
            Prefs.delete(key: "local_fav_removed.\(network.rawValue)")
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

    // MARK: - Network Selection

    func selectNetwork(_ network: Network) {
        guard network != selectedNetwork else { return }
        selectedNetwork = network
        searchText = ""
        Prefs.save(key: "selected_network", value: network.rawValue)

        if networkDataCache[network]?.isLoaded == true {
            return
        }

        Task {
            await loadChannels(for: network)
        }
    }

    // MARK: - Data Loading

    func loadChannels(for network: Network? = nil, restoreStation: Bool = false) async {
        let target = network ?? selectedNetwork
        guard let key = listenKey else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let channelsFetch = DIClient.fetchChannels(listenKey: key, quality: selectedQuality, network: target)
            async let favoritesFetch: Void = loadFavorites(for: target)
            let fetchedChannels = try await channelsFetch
            await favoritesFetch

            var data = networkDataCache[target] ?? NetworkData()
            data.channels = fetchedChannels
            data.isLoaded = true
            networkDataCache[target] = data

            log.info("loadChannels(\(target.rawValue)): \(fetchedChannels.count) channels loaded")

            // Only auto-resume the saved station at app launch — never when the
            // user is merely browsing to another network.
            if restoreStation && target == selectedNetwork {
                restoreSavedStationIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
            log.error("loadChannels(\(target.rawValue)) error: \(error.localizedDescription)")
        }
    }

    func loadFavorites(for network: Network? = nil) async {
        let target = network ?? selectedNetwork
        var data = networkDataCache[target] ?? NetworkData()
        guard let ak = apiKey else {
            log.warning("loadFavorites(\(target.rawValue)): SKIPPED — no apiKey")
            data.favoritesLoadFailed = true
            networkDataCache[target] = data
            return
        }
        do {
            let ids = try await DIClient.fetchFavorites(apiKey: ak, network: target)
            data.favoriteChannelIds = applyLocalFavoriteOverrides(to: ids, network: target)
            data.favoritesLoadFailed = false
            log.info("loadFavorites(\(target.rawValue)): \(ids.count) favorites")
        } catch {
            data.favoritesLoadFailed = true
            log.error("loadFavorites(\(target.rawValue)) error: \(error.localizedDescription)")
        }
        networkDataCache[target] = data
    }

    // MARK: - Favorites Toggle

    func toggleFavorite(_ channel: Channel) {
        let network = selectedNetwork
        var data = networkDataCache[network] ?? NetworkData()
        let adding = !data.favoriteChannelIds.contains(channel.id)
        if adding {
            data.favoriteChannelIds.insert(channel.id)
            sessionUnfavorited[network]?.remove(channel.id)
        } else {
            data.favoriteChannelIds.remove(channel.id)
            sessionUnfavorited[network, default: []].insert(channel.id)
        }
        networkDataCache[network] = data
        log.info("toggleFavorite(\(network.rawValue)): \(adding ? "add" : "remove") \(channel.name)")

        guard favoritesSyncAvailable, let ak = apiKey, let mid = memberId else {
            recordLocalFavoriteOverride(channelId: channel.id, adding: adding, network: network)
            return
        }

        Task {
            do {
                // Bulk-replace endpoint: read the server's ordered list, apply
                // this one change, and write the merged result back.
                var ids = try await DIClient.fetchFavoritesOrdered(apiKey: ak, network: network)
                if adding {
                    if !ids.contains(channel.id) { ids.append(channel.id) }
                } else {
                    ids.removeAll { $0 == channel.id }
                }
                try await DIClient.setFavorites(channelIds: ids, memberId: mid, apiKey: ak, network: network)
                clearLocalFavoriteOverrides(for: network)
                await loadFavorites(for: network)
            } catch {
                if case DIClientError.httpError(let code) = error, code == 404 || code == 405 {
                    favoritesSyncAvailable = false
                }
                recordLocalFavoriteOverride(channelId: channel.id, adding: adding, network: network)
                log.error("toggleFavorite(\(network.rawValue)) sync failed: \(error.localizedDescription)")
            }
        }
    }

    /// Local additions/removals that couldn't be synced, persisted per network
    /// and re-applied on top of whatever the server returns.
    private func localFavoriteOverrides(for network: Network) -> (added: Set<Int>, removed: Set<Int>) {
        func read(_ key: String) -> Set<Int> {
            Set((Prefs.read(key: "\(key).\(network.rawValue)") ?? "")
                .split(separator: ",").compactMap { Int($0) })
        }
        return (read("local_fav_added"), read("local_fav_removed"))
    }

    private func recordLocalFavoriteOverride(channelId: Int, adding: Bool, network: Network) {
        var (added, removed) = localFavoriteOverrides(for: network)
        if adding {
            added.insert(channelId)
            removed.remove(channelId)
        } else {
            removed.insert(channelId)
            added.remove(channelId)
        }
        Prefs.save(key: "local_fav_added.\(network.rawValue)", value: added.map(String.init).joined(separator: ","))
        Prefs.save(key: "local_fav_removed.\(network.rawValue)", value: removed.map(String.init).joined(separator: ","))
    }

    private func clearLocalFavoriteOverrides(for network: Network) {
        Prefs.delete(key: "local_fav_added.\(network.rawValue)")
        Prefs.delete(key: "local_fav_removed.\(network.rawValue)")
    }

    private func applyLocalFavoriteOverrides(to ids: Set<Int>, network: Network) -> Set<Int> {
        let (added, removed) = localFavoriteOverrides(for: network)
        return ids.union(added).subtracting(removed)
    }

    func loadMembership() async {
        guard let ak = apiKey else {
            subscriptions = []
            return
        }

        do {
            let profile = try await DIClient.fetchMembership(apiKey: ak)
            subscriptions = profile.subscriptions ?? []
            if let resolvedMemberId = profile.resolvedMemberId, resolvedMemberId != memberId {
                memberId = resolvedMemberId
                Prefs.save(key: "member_id", value: String(resolvedMemberId))
            }
            // Log real network_ids so the Network.networkId mapping can be verified in Console
            let summary = subscriptions
                .map { "network_id=\($0.networkId?.description ?? "nil") status=\($0.status ?? "?")" }
                .joined(separator: "; ")
            log.info("loadMembership: \(self.subscriptions.count) subscriptions [\(summary, privacy: .public)]")
        } catch {
            log.error("loadMembership error: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    func playChannel(_ channel: Channel) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality, network: selectedNetwork)
        else { return }
        Prefs.save(key: "last_station_id.\(selectedNetwork.rawValue)", value: String(channel.id))
        playingNetwork = selectedNetwork
        log.info("playChannel: \(channel.name) on \(self.selectedNetwork.rawValue) -> \(url)")
        audioPlayer.play(channel: channel, streamURL: url, network: selectedNetwork)
    }

    func restartStreamForQualityChange() {
        guard audioPlayer.isPlaying,
              let channel = audioPlayer.currentChannel,
              let network = playingNetwork,
              let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality, network: network)
        else { return }
        log.info("restartStreamForQualityChange: \(channel.name) at \(self.selectedQuality.rawValue)")
        audioPlayer.play(channel: channel, streamURL: url, network: network)
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    private func restoreSavedStationIfNeeded() {
        guard audioPlayer.currentChannel == nil else { return }
        guard let raw = Prefs.read(key: "last_station_id.\(selectedNetwork.rawValue)"),
              let channelId = Int(raw)
        else { return }
        guard let channel = channels.first(where: { $0.id == channelId }) else {
            log.warning("restoreSavedStationIfNeeded: saved station id=\(raw, privacy: .public) not found on \(self.selectedNetwork.rawValue)")
            return
        }

        log.info("restoreSavedStationIfNeeded: restoring '\(channel.name, privacy: .public)' on \(self.selectedNetwork.rawValue)")
        playChannel(channel)
    }

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
