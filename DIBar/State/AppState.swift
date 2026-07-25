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

    // Recently played stations, most recent first, across all networks
    var recentStations: [RecentStation] = []
    private static let recentStationsLimit = 8

    // Playback
    let audioPlayer = AudioPlayer()

    // Listening history
    let historyRecorder: HistoryRecorder
    var saveListeningHistory: Bool = Prefs.bool(.saveHistory, default: true) {
        didSet {
            Prefs.set(saveListeningHistory, for: .saveHistory)
            historyRecorder.setEnabled(saveListeningHistory)
        }
    }

    // Scrobbling
    let scrobbler: Scrobbler

    // Track-change notifications
    let trackNotifier: TrackNotifier
    /// Shown under the Settings row when macOS denied notification permission.
    var notifyPermissionHint: String?
    var notifyTrackChanges: Bool = Prefs.bool(.notifyTrackChanges, default: false) {
        didSet {
            Prefs.set(notifyTrackChanges, for: .notifyTrackChanges)
            trackNotifier.setEnabled(notifyTrackChanges)
            guard notifyTrackChanges else { return }
            notifyPermissionHint = nil
            trackNotifier.requestAuthorization { [weak self] granted in
                guard let self, !granted else { return }
                self.notifyTrackChanges = false
                self.notifyPermissionHint = "Enable DIBar in System Settings → Notifications"
            }
        }
    }
    /// Banner after a hotkey-driven channel/site switch — the feedback that
    /// makes switching without the popover open usable. Default ON.
    var notifySwitchChanges: Bool = Prefs.bool(.notifyChannelSwitch, default: true) {
        didSet {
            Prefs.set(notifySwitchChanges, for: .notifyChannelSwitch)
            guard notifySwitchChanges else { return }
            notifyPermissionHint = nil
            trackNotifier.requestAuthorization { [weak self] granted in
                guard let self, !granted else { return }
                self.notifySwitchChanges = false
                self.notifyPermissionHint = "Enable DIBar in System Settings → Notifications"
            }
        }
    }

    // Output device routing
    let deviceManager = AudioDeviceManager()
    /// The user's chosen device UID; kept even while the device is absent so
    /// the route re-applies when it comes back.
    var outputDeviceUID: String? = Prefs.string(.outputDeviceUID)

    func setOutputDevice(uid: String?) {
        outputDeviceUID = uid
        Prefs.set(uid, for: .outputDeviceUID)
        applyOutputDevice()
    }

    private func applyOutputDevice() {
        let available = outputDeviceUID.map { uid in
            deviceManager.devices.contains { $0.uid == uid }
        } ?? false
        audioPlayer.setOutputDevice(uid: available ? outputDeviceUID : nil)
    }

    // Global hotkeys — default on for new installs; existing installs that
    // never touched the setting are pinned off by the Prefs v2 migration.
    private let hotkeyManager = HotkeyManager()
    var globalHotkeysEnabled: Bool = Prefs.bool(.globalHotkeys, default: true) {
        didSet {
            Prefs.set(globalHotkeysEnabled, for: .globalHotkeys)
            hotkeyManager.setEnabled(globalHotkeysEnabled)
        }
    }

    // Sleep timer — session-only; never persisted across launches
    var sleepTimerEndDate: Date?
    private var sleepTimerTimer: Timer?
    var sleepTimerQuitsApp: Bool = Prefs.bool(.sleepTimerQuits, default: false) {
        didSet { Prefs.set(sleepTimerQuitsApp, for: .sleepTimerQuits) }
    }

    // Settings
    var selectedQuality: StreamQuality =
        Prefs.string(.quality).flatMap(StreamQuality.init(rawValue:)) ?? .premiumHigh
    var subscriptions: [MembershipSubscription] = []

    // UI
    var isLoading: Bool = false
    var errorMessage: String?
    var searchFieldFocused: Bool = false
    var artworkExpanded: Bool = false
    // Menu bar label components. "Site" in the UI, Network in code.
    // All components default ON for new installs; existing installs that never
    // touched them are pinned off by the Prefs v2 migration.
    var menuBarShowPlayState: Bool = Prefs.bool(.menuBarShowPlayState, default: true) {
        didSet { Prefs.set(menuBarShowPlayState, for: .menuBarShowPlayState) }
    }
    var menuBarShowSite: Bool = Prefs.bool(.menuBarShowSite, default: true) {
        didSet { Prefs.set(menuBarShowSite, for: .menuBarShowSite) }
    }
    var menuBarShowStation: Bool = Prefs.bool(.menuBarShowStation, default: true) {
        didSet { Prefs.set(menuBarShowStation, for: .menuBarShowStation) }
    }
    var menuBarShowArtist: Bool = Prefs.bool(.menuBarShowArtist, default: true) {
        didSet { Prefs.set(menuBarShowArtist, for: .menuBarShowArtist) }
    }
    var menuBarShowSong: Bool = Prefs.bool(.menuBarShowSong, default: true) {
        didSet { Prefs.set(menuBarShowSong, for: .menuBarShowSong) }
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

    /// Subscriptions are account-level and managed on DI's site — the sibling
    /// domains have no subscription page of their own.
    static let subscriptionURL = URL(string: "https://www.di.fm/member/subscription")!
    var subscriptionURL: URL { Self.subscriptionURL }

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
        trackNotifier = TrackNotifier(player: audioPlayer)
        scrobbler = Scrobbler(recorder: historyRecorder)
        historyRecorder.setEnabled(saveListeningHistory)
        historyRecorder.start()
        historyRecorder.onTrackStarted = { [weak self] artist, title, duration in
            self?.scrobbler.trackStarted(artist: artist, title: title, duration: duration)
        }
        historyRecorder.onSegmentClosed = { [weak self] artist, title, duration, startedAt, endedAt, reason in
            self?.scrobbler.segmentClosed(
                artist: artist, title: title, duration: duration,
                startedAt: startedAt, endedAt: endedAt, reason: reason
            )
        }
        scrobbler.start()
        trackNotifier.setEnabled(notifyTrackChanges)
        trackNotifier.start()
        // Ask for notification permission up front — a deliberate first-launch
        // moment instead of a prompt buried under a hotkey press.
        if notifySwitchChanges || notifyTrackChanges {
            trackNotifier.requestAuthorization { [weak self] granted in
                guard let self, !granted else { return }
                self.notifySwitchChanges = false
                self.notifyTrackChanges = false
                self.notifyPermissionHint = "Enable DIBar in System Settings → Notifications"
            }
        }
        audioPlayer.onNextTrack = { [weak self] in self?.cycleToNextFavorite() }
        audioPlayer.onPreviousTrack = { [weak self] in self?.cycleToPreviousFavorite() }
        hotkeyManager.onAction = { [weak self] action in
            log.info("hotkey action: \(String(describing: action), privacy: .public)")
            switch action {
            case .playPause: self?.togglePlayPause()
            case .nextFavorite: self?.cycleToNextFavorite()
            case .previousFavorite: self?.cycleToPreviousFavorite()
            case .nextSite: self?.cycleToNextSite()
            case .previousSite: self?.cycleToPreviousSite()
            }
        }
        hotkeyManager.setEnabled(globalHotkeysEnabled)
        deviceManager.onDevicesChanged = { [weak self] in
            self?.applyOutputDevice()
        }
        applyOutputDevice()
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

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

        loadRecentStations()

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
        Prefs.set(nil, for: .recentStations)
        recentStations = []
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

    // MARK: - Network Selection

    func selectNetwork(_ network: Network) {
        guard network != selectedNetwork else { return }
        selectedNetwork = network
        searchText = ""
        Prefs.set(network.rawValue, for: .selectedNetwork)

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
        (Prefs.intSet(.localFavAdded, network: network),
         Prefs.intSet(.localFavRemoved, network: network))
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
        Prefs.set(added, for: .localFavAdded, network: network)
        Prefs.set(removed, for: .localFavRemoved, network: network)
    }

    private func clearLocalFavoriteOverrides(for network: Network) {
        Prefs.set(nil, for: .localFavAdded, network: network)
        Prefs.set(nil, for: .localFavRemoved, network: network)
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
                Prefs.set(resolvedMemberId, for: .memberId)
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
        playChannel(channel, on: selectedNetwork)
    }

    private func playChannel(_ channel: Channel, on network: Network) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality, network: network)
        else { return }
        Prefs.set(channel.id, for: .lastStationId, network: network)
        playingNetwork = network
        recordRecentStation(channel, network: network)
        log.info("playChannel: \(channel.name) on \(network.rawValue) -> \(url)")
        audioPlayer.play(channel: channel, streamURL: url, network: network)
    }

    /// Hotkey actions: jump to the next/previous favorite (alphabetical,
    /// wrapping) on the network that's playing — or the browsed one when idle.
    func cycleToNextFavorite() { cycleFavorite(offset: 1) }
    func cycleToPreviousFavorite() { cycleFavorite(offset: -1) }

    private func cycleFavorite(offset: Int) {
        let network = playingNetwork ?? selectedNetwork
        guard let data = networkDataCache[network] else { return }
        let favorites = data.channels
            .filter { data.favoriteChannelIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !favorites.isEmpty else { return }
        let count = favorites.count
        let base: Int
        if let current = favorites.firstIndex(where: { $0.id == audioPlayer.currentChannel?.id }) {
            base = current + offset
        } else {
            // Idle: forward starts at the first favorite, back at the last
            base = offset > 0 ? 0 : count - 1
        }
        playChannel(favorites[((base % count) + count) % count], on: network)
        announceSwitchIfEnabled()
    }

    /// Hotkey actions: step through the sites (declaration order, wrapping),
    /// resuming each site's last played channel.
    func cycleToNextSite() { cycleSite(offset: 1) }
    func cycleToPreviousSite() { cycleSite(offset: -1) }

    private func cycleSite(offset: Int) {
        let all = Network.allCases
        let current = playingNetwork ?? selectedNetwork
        guard let index = all.firstIndex(of: current) else { return }
        let count = all.count
        switchSiteAndPlay(all[(((index + offset) % count) + count) % count])
    }

    /// Selects the site in the UI and starts its most sensible channel: the
    /// one last played there, else the first favorite, else the first channel.
    /// Inlines the selection instead of calling selectNetwork(_:) so its
    /// fire-and-forget loadChannels Task can't race the awaited one here.
    private func switchSiteAndPlay(_ network: Network) {
        if network != selectedNetwork {
            selectedNetwork = network
            searchText = ""
            Prefs.set(network.rawValue, for: .selectedNetwork)
        }
        Task {
            if networkDataCache[network]?.isLoaded != true {
                await loadChannels(for: network)
            }
            guard let data = networkDataCache[network], !data.channels.isEmpty else { return }
            let target: Channel
            if let id = Prefs.int(.lastStationId, network: network),
               let saved = data.channels.first(where: { $0.id == id }) {
                target = saved
            } else {
                let sorted = data.channels
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                target = sorted.first { data.favoriteChannelIds.contains($0.id) } ?? sorted[0]
            }
            playChannel(target, on: network)
            announceSwitchIfEnabled()
        }
    }

    // No authorization round-trip here: permission is ensured at launch and on
    // toggle-on, and a transient failure must never silently kill the feature.
    // A keyboard switch also changes the song, so either toggle earns the
    // banner (which carries both the channel and the track).
    private func announceSwitchIfEnabled() {
        guard notifySwitchChanges || notifyTrackChanges else { return }
        trackNotifier.announceSwitch()
    }

    // MARK: - Recently Played Stations

    /// Plays a recent entry, switching networks first when needed. Stale
    /// entries (station gone from the channel list) self-heal by dropping out.
    func playRecentStation(_ entry: RecentStation) {
        Task {
            if selectedNetwork != entry.network {
                selectNetwork(entry.network)
            }
            if networkDataCache[entry.network]?.isLoaded != true {
                await loadChannels(for: entry.network)
            }
            guard let channel = channels.first(where: { $0.id == entry.channelId }) else {
                log.warning("playRecentStation: '\(entry.name, privacy: .public)' no longer on \(entry.network.rawValue)")
                recentStations.removeAll { $0.id == entry.id }
                persistRecentStations()
                return
            }
            playChannel(channel)
        }
    }

    private func recordRecentStation(_ channel: Channel, network: Network) {
        let entry = RecentStation(network: network, channelId: channel.id, channelKey: channel.key, name: channel.name)
        recentStations.removeAll { $0.network == network && $0.channelId == channel.id }
        recentStations.insert(entry, at: 0)
        if recentStations.count > Self.recentStationsLimit {
            recentStations.removeLast(recentStations.count - Self.recentStationsLimit)
        }
        persistRecentStations()
    }

    private func loadRecentStations() {
        guard let raw = Prefs.string(.recentStations),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentStation].self, from: data)
        else { return }
        recentStations = decoded
    }

    private func persistRecentStations() {
        guard let data = try? JSONEncoder().encode(recentStations),
              let json = String(data: data, encoding: .utf8)
        else { return }
        Prefs.set(json, for: .recentStations)
    }

    // MARK: - Song Votes

    /// The user's local vote on the current track (+1 / -1), nil when unvoted.
    var currentTrackVote: Int?

    func refreshCurrentTrackVote() {
        guard let trackId = audioPlayer.currentTrack?.trackId else {
            currentTrackVote = nil
            return
        }
        currentTrackVote = historyRecorder.vote(forTrackId: trackId)
    }

    func voteCurrentTrack(up: Bool) {
        guard let track = audioPlayer.currentTrack,
              let trackId = track.trackId,
              let channel = audioPlayer.currentChannel,
              let network = audioPlayer.currentNetwork
        else { return }

        let newVote = up ? 1 : -1
        if historyRecorder.vote(forTrackId: trackId) == newVote {
            // Tapping the same thumb again removes the vote
            historyRecorder.clearVote(trackId: trackId)
            currentTrackVote = nil
            if let ak = apiKey {
                Task {
                    try? await DIClient.removeVote(trackId: trackId, channelId: channel.id, apiKey: ak, network: network)
                }
            }
        } else {
            historyRecorder.recordVote(
                trackId: trackId, vote: newVote,
                artist: track.artist, title: track.title,
                network: network.rawValue, channelId: channel.id, channelName: channel.name,
                artPath: TrackArt.storagePath(from: track.artURL)
            )
            currentTrackVote = newVote
            if let ak = apiKey {
                Task {
                    do {
                        try await DIClient.castVote(trackId: trackId, channelId: channel.id, up: up, apiKey: ak, network: network)
                        historyRecorder.markVoteSynced(trackId: trackId)
                    } catch {
                        log.error("vote sync failed: \(error.localizedDescription)")
                    }
                }
            }
        }
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

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        let clamped = min(max(minutes, 1), 720)
        sleepTimerEndDate = Date().addingTimeInterval(TimeInterval(clamped * 60))
        // A 1s date-compare timer instead of a one-shot: after system sleep the
        // next tick still fires an overdue timer correctly.
        if sleepTimerTimer == nil {
            sleepTimerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sleepTimerTick() }
            }
        }
        log.info("sleep timer: set for \(clamped)min")
    }

    func cancelSleepTimer() {
        sleepTimerEndDate = nil
        sleepTimerTimer?.invalidate()
        sleepTimerTimer = nil
    }

    private func sleepTimerTick() {
        guard let end = sleepTimerEndDate, Date() >= end else { return }
        cancelSleepTimer()
        log.info("sleep timer: fired")
        audioPlayer.pause()
        if sleepTimerQuitsApp {
            NSApp.terminate(nil)
        }
    }

    private func restoreSavedStationIfNeeded() {
        guard audioPlayer.currentChannel == nil else { return }
        guard let channelId = Prefs.int(.lastStationId, network: selectedNetwork) else { return }
        guard let channel = channels.first(where: { $0.id == channelId }) else {
            log.warning("restoreSavedStationIfNeeded: saved station id=\(channelId) not found on \(self.selectedNetwork.rawValue)")
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
