import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

/// Favorites: server sync (bulk-replace endpoint) with local overrides that
/// persist per network when sync isn't available.
extension AppState {
    func favoriteChannelIds(on network: Network) -> Set<Int> {
        networkDataCache[network]?.favoriteChannelIds ?? []
    }

    var favoritesLoadFailed: Bool {
        displayedNetworks.contains { networkDataCache[$0]?.favoritesLoadFailed ?? false }
    }

    var favoriteChannels: [NetworkChannel] {
        displayedNetworks.flatMap { network -> [NetworkChannel] in
            let visible = favoriteChannelIds(on: network).union(sessionUnfavorited[network] ?? [])
            return (networkDataCache[network]?.channels ?? [])
                .filter { visible.contains($0.id) }
                .map { NetworkChannel(network: network, channel: $0) }
        }
        .sorted(by: Self.channelOrder)
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

    /// Reloads favorites for exactly the displayed networks whose last load
    /// failed (the Retry row's action; a no-op for the rest).
    func retryFailedFavorites() async {
        for network in displayedNetworks where networkDataCache[network]?.favoritesLoadFailed ?? false {
            await loadFavorites(for: network)
        }
    }

    func toggleFavorite(_ channel: Channel, on network: Network? = nil) {
        let network = network ?? selectedNetwork
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
}
