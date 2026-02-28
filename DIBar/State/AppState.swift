import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

@Observable
@MainActor
final class AppState {
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

    // MARK: - Lifecycle

    func bootstrap() async {
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
            await loadChannels()
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

    func playChannel(_ channel: Channel) {
        guard let key = listenKey,
              let url = DIClient.streamURL(channelKey: channel.key, listenKey: key, quality: selectedQuality)
        else { return }
        log.info("playChannel: \(channel.name) -> \(url)")
        audioPlayer.play(channel: channel, streamURL: url)
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }
}
