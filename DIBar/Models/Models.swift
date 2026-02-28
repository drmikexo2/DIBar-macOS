import Foundation

// MARK: - Stream Quality

enum StreamQuality: String, CaseIterable, Identifiable, Codable {
    case premiumHigh = "premium_high"
    case premium = "premium"
    case premiumMedium = "premium_medium"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .premiumHigh: "320k MP3"
        case .premium: "128k AAC"
        case .premiumMedium: "64k AAC"
        }
    }
}

// MARK: - Channel

struct Channel: Codable, Identifiable, Hashable {
    let id: Int
    let key: String
    let name: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id, key, name, description
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Auth

struct AuthResponse: Codable {
    let listenKey: String
    let id: Int?
    let memberId: Int?
    let apiKey: String?
    let member: AuthMember?

    struct AuthMember: Codable {
        let id: Int?
    }

    enum CodingKeys: String, CodingKey {
        case listenKey = "listen_key"
        case id
        case memberId = "member_id"
        case apiKey = "api_key"
        case member
    }

    var resolvedMemberId: Int? {
        id ?? memberId ?? member?.id
    }
}

// MARK: - Favorites

struct FavoriteChannel: Codable {
    let id: Int?
    let channelId: Int?
    let position: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case position
    }

    /// Best effort to get the channel ID
    var resolvedChannelId: Int? {
        channelId ?? id
    }
}

// MARK: - Track / Now Playing

struct TrackVotes: Codable, Equatable {
    let up: Int?
    let down: Int?
}

struct TrackHistoryItem: Codable {
    let track: String?
    let artist: String?
    let title: String?
    let channelId: Int?
    let artUrl: String?
    let duration: Int?
    let started: Int?
    let votes: TrackVotes?
    let trackId: Int?

    enum CodingKeys: String, CodingKey {
        case track, artist, title, duration, started, votes
        case channelId = "channel_id"
        case artUrl = "art_url"
        case trackId = "track_id"
    }
}

struct NowPlaying: Equatable {
    let channelName: String
    let artist: String
    let title: String
    let artURL: URL?
    let duration: Int
    let startedAt: Date?
    let upVotes: Int
    let downVotes: Int

    var displayText: String {
        if artist.isEmpty && title.isEmpty { return channelName }
        if artist.isEmpty { return title }
        return "\(artist) — \(title)"
    }

    var timeRemaining: Int? {
        guard let startedAt, duration > 0 else { return nil }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let remaining = duration - elapsed
        return remaining > 0 ? remaining : nil
    }

    static func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Batch Update Response

struct BatchUpdateResponse: Codable {
    let channelFilters: [ChannelFilter]?

    enum CodingKeys: String, CodingKey {
        case channelFilters = "channel_filters"
    }
}

struct ChannelFilter: Codable {
    let id: Int?
    let key: String?
    let name: String?
    let channels: [Channel]?
}
