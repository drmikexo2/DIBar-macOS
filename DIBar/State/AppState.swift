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
    // Internal (not private) so the topic extensions in AppState+*.swift can
    // reach it; nothing outside AppState's files should touch it.
    var didBootstrap = false

    // Auth
    var isLoggedIn: Bool = false
    var listenKey: String?
    var apiKey: String?
    var memberId: Int?
    var accountEmail: String?

    // Network
    var selectedNetwork: Network = .di
    /// True when the picker is on "All Sites". selectedNetwork keeps the last
    /// concrete network for hotkeys, membership, and station restore.
    var allNetworksSelected: Bool = false
    var playingNetwork: Network?
    var networkDataCache: [Network: NetworkData] = [:]

    // Search
    var searchText: String = ""

    // Recently played stations, most recent first, across all networks
    let recentStationsStore = RecentStationsStore()
    var recentStations: [RecentStation] { recentStationsStore.entries }

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
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
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
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
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
    let sleepTimer = SleepTimer()
    var sleepTimerEndDate: Date? { sleepTimer.endDate }
    var sleepTimerQuitsApp: Bool = Prefs.bool(.sleepTimerQuits, default: false) {
        didSet { Prefs.set(sleepTimerQuitsApp, for: .sleepTimerQuits) }
    }

    // Settings
    var selectedQuality: StreamQuality =
        Prefs.string(.quality).flatMap(StreamQuality.init(rawValue:)) ?? .premiumHigh
    var subscriptions: [MembershipSubscription] = []

    // UI
    var isLoading: Bool = false
    /// In-flight loadChannels calls; see the counter comment there.
    @ObservationIgnored private var channelLoadCount = 0
    var errorMessage: String?
    var searchFieldFocused: Bool = false
    var artworkExpanded: Bool = false
    /// Shared frame for the low-rate playing-speaker animation. AppDelegate
    /// advances this only while the panel is visible and audio is audible;
    /// every visible indicator reads the same frame instead of owning an
    /// independent animation clock.
    var speakerWaveFrame: Int = 0
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
    var sessionUnfavorited: [Network: Set<Int>] = [:]

    // MARK: - Computed

    var channels: [Channel] {
        networkDataCache[selectedNetwork]?.channels ?? []
    }

    /// The networks the channel list currently shows.
    var displayedNetworks: [Network] {
        allNetworksSelected ? Network.allCases : [selectedNetwork]
    }

    /// Gates the loading placeholder: false only when nothing is showable yet.
    var hasAnyDisplayedChannels: Bool {
        displayedNetworks.contains { networkDataCache[$0]?.channels.isEmpty == false }
    }

    var filteredChannels: [NetworkChannel] {
        Self.filteredChannels(cache: networkDataCache, networks: displayedNetworks, searchText: searchText)
    }

    /// Pure so tests can exercise the merge/sort/filter directly.
    static func filteredChannels(
        cache: [Network: NetworkData], networks: [Network], searchText: String
    ) -> [NetworkChannel] {
        let all = networks.flatMap { network in
            (cache[network]?.channels ?? []).map { NetworkChannel(network: network, channel: $0) }
        }
        let sorted = all.sorted(by: Self.channelOrder)
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.channel.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Alphabetical by channel name; same-named channels from different
    /// networks tie-break on network name so order is stable.
    static func channelOrder(_ lhs: NetworkChannel, _ rhs: NetworkChannel) -> Bool {
        let cmp = lhs.channel.name.localizedCaseInsensitiveCompare(rhs.channel.name)
        if cmp != .orderedSame { return cmp == .orderedAscending }
        return lhs.network.displayName < rhs.network.displayName
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
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
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
        sleepTimer.onFire = { [weak self] in
            guard let self else { return }
            self.audioPlayer.pause()
            if self.sleepTimerQuitsApp {
                NSApp.terminate(nil)
            }
        }
        deviceManager.onDevicesChanged = { [weak self] in
            self?.applyOutputDevice()
        }
        applyOutputDevice()
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    // MARK: - Network Selection

    func selectNetwork(_ network: Network) {
        guard applyNetworkSelection(network) else { return }

        if networkDataCache[network]?.isLoaded == true {
            return
        }

        Task {
            await loadChannels(for: network)
        }
    }

    /// Shared selection step for selectNetwork and switchSiteAndPlay: updates
    /// the UI state and persists the choice, without any loading side effects
    /// (the callers decide how to load, which is what keeps switchSiteAndPlay's
    /// awaited load from racing selectNetwork's fire-and-forget one).
    @discardableResult
    private func applyNetworkSelection(_ network: Network) -> Bool {
        // The second clause matters: while in All-Sites mode, picking the
        // remembered network must still exit All mode, not no-op.
        guard network != selectedNetwork || allNetworksSelected else { return false }
        allNetworksSelected = false
        Prefs.set(false, for: .allNetworksSelected)
        selectedNetwork = network
        searchText = ""
        Prefs.set(network.rawValue, for: .selectedNetwork)
        return true
    }

    /// Switches the picker to "All Sites": every network's channels and
    /// favorites merged into one list.
    func selectAllNetworks() {
        guard !allNetworksSelected else { return }
        allNetworksSelected = true
        searchText = ""
        Prefs.set(true, for: .allNetworksSelected)
        Task {
            await loadAllNetworks()
        }
    }

    /// Fills the cache for any network not yet loaded, in parallel.
    func loadAllNetworks() async {
        await withTaskGroup(of: Void.self) { group in
            for network in Network.allCases where networkDataCache[network]?.isLoaded != true {
                group.addTask { await self.loadChannels(for: network) }
            }
        }
    }

    // MARK: - Data Loading

    func loadChannels(for network: Network? = nil, restoreStation: Bool = false) async {
        let target = network ?? selectedNetwork
        guard listenKey != nil else { return }
        // Counted, not toggled: loadAllNetworks runs these concurrently and
        // the first finisher must not clear the flag for the rest. (login()'s
        // direct isLoading writes never overlap channel loads.)
        channelLoadCount += 1
        isLoading = true
        defer {
            channelLoadCount -= 1
            if channelLoadCount == 0 { isLoading = false }
        }

        do {
            async let channelsFetch = DIClient.fetchChannels(network: target)
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

    // MARK: - Playback

    func playChannel(_ channel: Channel) {
        playChannel(channel, on: selectedNetwork)
    }

    func playChannel(_ item: NetworkChannel) {
        playChannel(item.channel, on: item.network)
    }

    func playChannel(_ channel: Channel, on network: Network) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality, network: network)
        else { return }
        Prefs.set(channel.id, for: .lastStationId, network: network)
        playingNetwork = network
        recentStationsStore.record(channel, network: network)
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
    /// Uses applyNetworkSelection (not selectNetwork) so selectNetwork's
    /// fire-and-forget loadChannels Task can't race the awaited one here.
    private func switchSiteAndPlay(_ network: Network) {
        applyNetworkSelection(network)
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
            // In All-Sites mode the entry is already on screen; don't yank the
            // picker to its network.
            if !allNetworksSelected && selectedNetwork != entry.network {
                selectNetwork(entry.network)
            }
            if networkDataCache[entry.network]?.isLoaded != true {
                await loadChannels(for: entry.network)
            }
            guard let channel = networkDataCache[entry.network]?.channels
                .first(where: { $0.id == entry.channelId }) else {
                log.warning("playRecentStation: '\(entry.name, privacy: .public)' no longer on \(entry.network.rawValue)")
                recentStationsStore.remove(id: entry.id)
                return
            }
            playChannel(channel, on: entry.network)
        }
    }

    /// Fetches favorites for networks that appear in Recently Played but have
    /// no cache entry yet, so recent rows show correct star state.
    /// (loadFavorites writes a NetworkData entry even on failure, making the
    /// nil check a fetch-once-per-session guard.)
    func loadFavoritesForRecents() async {
        for network in Set(recentStations.map(\.network)) where networkDataCache[network] == nil {
            await loadFavorites(for: network)
        }
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
        sleepTimer.start(minutes: minutes)
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
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
