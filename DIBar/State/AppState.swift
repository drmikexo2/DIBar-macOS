import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

@Observable
@MainActor
final class AppState {
    private static let favoriteStationKey = "favorite_station_id"
    static let subscriptionURL = URL(string: "https://www.di.fm/account/subscriptions")!
    private var didBootstrap = false

    // Auth
    var isLoggedIn: Bool = false
    var listenKey: String?
    var apiKey: String?
    var memberId: Int?

    // Data
    var channels: [Channel] = []
    var favoriteChannelIds: Set<Int> = []
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
                async let channelsLoad: Void = loadChannels()
                async let membershipLoad: Void = loadMembership()
                _ = await (channelsLoad, membershipLoad)
            } else {
                await loadChannels()
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
            await loadChannels()
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
        listenKey = nil
        apiKey = nil
        memberId = nil
        membershipSubscription = nil
        isLoggedIn = false
        channels = []
        favoriteChannelIds = []
        searchText = ""
        errorMessage = nil
    }

    func loadChannels() async {
        guard let key = listenKey else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            channels = try await DIClient.fetchChannels(listenKey: key, quality: selectedQuality)
            log.info("loadChannels: \(self.channels.count) channels loaded")
            await loadFavorites()
            restoreSavedStationIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            log.error("loadChannels error: \(error.localizedDescription)")
        }
    }

    func loadFavorites() async {
        guard let ak = apiKey else {
            log.warning("loadFavorites: SKIPPED — no apiKey")
            return
        }
        log.info("loadFavorites: calling API with apiKey")
        let ids = (try? await DIClient.fetchFavorites(apiKey: ak)) ?? []
        favoriteChannelIds = ids
        log.info("loadFavorites: \(self.favoriteChannelIds.count) favorites set, favoriteChannels=\(self.favoriteChannels.count)")
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

    func playChannel(_ channel: Channel) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality)
        else { return }
        KeychainHelper.save(key: Self.favoriteStationKey, value: String(channel.id))
        log.info("playChannel: \(channel.name) -> \(url)")
        audioPlayer.play(channel: channel, streamURL: url)
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    private func restoreSavedStationIfNeeded() {
        guard audioPlayer.currentChannel == nil else { return }
        guard let raw = KeychainHelper.read(key: Self.favoriteStationKey),
              let channelId = Int(raw)
        else { return }
        guard let channel = channels.first(where: { $0.id == channelId }) else {
            log.warning("restoreSavedStationIfNeeded: saved station id=\(raw, privacy: .public) not found in channel list")
            return
        }

        log.info("restoreSavedStationIfNeeded: restoring '\(channel.name, privacy: .public)'")
        playChannel(channel)
    }

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
