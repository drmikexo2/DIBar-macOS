import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

struct NetworkData {
    var channels: [Channel] = []
    var favoriteChannelIds: Set<Int> = []
    var isLoaded: Bool = false
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

    // Settings
    var selectedQuality: StreamQuality = {
        if let raw = KeychainHelper.read(key: "quality"), let q = StreamQuality(rawValue: raw) {
            return q
        }
        return .premiumHigh
    }()
    var membershipSubscription: MembershipSubscription?

    // UI
    var isLoading: Bool = false
    var errorMessage: String?

    // MARK: - Computed

    var channels: [Channel] {
        networkDataCache[selectedNetwork]?.channels ?? []
    }

    var favoriteChannelIds: Set<Int> {
        networkDataCache[selectedNetwork]?.favoriteChannelIds ?? []
    }

    var favoriteChannels: [Channel] {
        channels
            .filter { favoriteChannelIds.contains($0.id) }
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

    var membershipHeaderLine: String {
        guard let status = membershipSubscription?.status?.capitalized, !status.isEmpty else {
            return "Membership"
        }
        return "Membership (\(status))"
    }

    var membershipDetailLine: String {
        guard let subscription = membershipSubscription else { return "Tap to manage subscription" }

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
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Migrate old single-station key to per-network
        if let oldStation = KeychainHelper.read(key: "favorite_station_id") {
            KeychainHelper.save(key: "favorite_station_id.di", value: oldStation)
            KeychainHelper.delete(key: "favorite_station_id")
            log.info("bootstrap: migrated favorite_station_id to favorite_station_id.di")
        }

        // Restore last selected network
        if let raw = KeychainHelper.read(key: "selected_network"), let net = Network(rawValue: raw) {
            selectedNetwork = net
            log.info("bootstrap: restored network=\(net.rawValue)")
        }

        log.info("bootstrap: checking stored credentials")
        if let key = KeychainHelper.read(key: "listen_key") {
            listenKey = key
            apiKey = KeychainHelper.read(key: "api_key")
            if let idStr = KeychainHelper.read(key: "member_id"), let id = Int(idStr) {
                memberId = id
                log.info("bootstrap: found stored memberId=\(id)")
            } else {
                log.warning("bootstrap: no stored member_id found")
            }
            log.info("bootstrap: apiKey=\(self.apiKey != nil ? "present" : "nil")")
            isLoggedIn = true
            if apiKey != nil {
                async let channelsLoad: Void = loadChannels(for: selectedNetwork)
                async let membershipLoad: Void = loadMembership()
                _ = await (channelsLoad, membershipLoad)
            } else {
                await loadChannels(for: selectedNetwork)
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
            KeychainHelper.save(key: "listen_key", value: response.listenKey)
            if let ak = response.apiKey {
                KeychainHelper.save(key: "api_key", value: ak)
                log.info("login: apiKey saved")
            } else {
                log.warning("login: apiKey is nil in auth response")
            }
            if let mid = response.resolvedMemberId {
                KeychainHelper.save(key: "member_id", value: String(mid))
                memberId = mid
                log.info("login: memberId=\(mid)")
            } else {
                log.warning("login: resolvedMemberId is nil! Auth response had no member ID.")
            }
            listenKey = response.listenKey
            apiKey = response.apiKey
            membershipSubscription = response.subscriptions?.first
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
        KeychainHelper.delete(key: "listen_key")
        KeychainHelper.delete(key: "api_key")
        KeychainHelper.delete(key: "member_id")
        KeychainHelper.delete(key: "selected_network")
        for network in Network.allCases {
            KeychainHelper.delete(key: "favorite_station_id.\(network.rawValue)")
        }
        listenKey = nil
        apiKey = nil
        memberId = nil
        membershipSubscription = nil
        isLoggedIn = false
        networkDataCache = [:]
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
        KeychainHelper.save(key: "selected_network", value: network.rawValue)

        if networkDataCache[network]?.isLoaded == true {
            return
        }

        Task {
            await loadChannels(for: network)
        }
    }

    // MARK: - Data Loading

    func loadChannels(for network: Network? = nil) async {
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

            if target == selectedNetwork {
                restoreSavedStationIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
            log.error("loadChannels(\(target.rawValue)) error: \(error.localizedDescription)")
        }
    }

    func loadFavorites(for network: Network? = nil) async {
        let target = network ?? selectedNetwork
        guard let ak = apiKey else {
            log.warning("loadFavorites: SKIPPED — no apiKey")
            return
        }
        log.info("loadFavorites(\(target.rawValue)): calling API")
        let ids = (try? await DIClient.fetchFavorites(apiKey: ak, network: target)) ?? []

        var data = networkDataCache[target] ?? NetworkData()
        data.favoriteChannelIds = ids
        networkDataCache[target] = data

        log.info("loadFavorites(\(target.rawValue)): \(ids.count) favorites")
    }

    func loadMembership() async {
        guard let ak = apiKey else {
            membershipSubscription = nil
            return
        }

        do {
            let profile = try await DIClient.fetchMembership(apiKey: ak)
            membershipSubscription = profile.subscriptions?.first
            if let resolvedMemberId = profile.resolvedMemberId, resolvedMemberId != memberId {
                memberId = resolvedMemberId
                KeychainHelper.save(key: "member_id", value: String(resolvedMemberId))
            }
            log.info("loadMembership: subscription present=\(self.membershipSubscription != nil)")
        } catch {
            log.error("loadMembership error: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    func playChannel(_ channel: Channel) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality, network: selectedNetwork)
        else { return }
        KeychainHelper.save(key: "favorite_station_id.\(selectedNetwork.rawValue)", value: String(channel.id))
        playingNetwork = selectedNetwork
        log.info("playChannel: \(channel.name) on \(self.selectedNetwork.rawValue) -> \(url)")
        audioPlayer.play(channel: channel, streamURL: url, network: selectedNetwork)
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    private func restoreSavedStationIfNeeded() {
        guard audioPlayer.currentChannel == nil else { return }
        guard let raw = KeychainHelper.read(key: "favorite_station_id.\(selectedNetwork.rawValue)"),
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
