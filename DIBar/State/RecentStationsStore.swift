import Foundation
import Observation

/// Recently played stations, most recent first, across all networks —
/// a small MRU list persisted as JSON in Prefs.
@Observable
@MainActor
final class RecentStationsStore {
    private(set) var entries: [RecentStation] = []
    private static let limit = 8

    func load() {
        guard let raw = Prefs.string(.recentStations),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentStation].self, from: data)
        else { return }
        entries = decoded
    }

    func record(_ channel: Channel, network: Network) {
        let entry = RecentStation(
            network: network, channelId: channel.id,
            channelKey: channel.key, name: channel.name
        )
        entries.removeAll { $0.network == network && $0.channelId == channel.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        persist()
    }

    /// Drops a stale entry (station no longer on its network).
    func remove(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        Prefs.set(nil, for: .recentStations)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8)
        else { return }
        Prefs.set(json, for: .recentStations)
    }
}
