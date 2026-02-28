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
    let subscriptions: [MembershipSubscription]?

    struct AuthMember: Codable {
        let id: Int?
    }

    enum CodingKeys: String, CodingKey {
        case listenKey = "listen_key"
        case id
        case memberId = "member_id"
        case apiKey = "api_key"
        case member
        case subscriptions
    }

    var resolvedMemberId: Int? {
        id ?? memberId ?? member?.id
    }
}

// MARK: - Membership

struct MembershipPlan: Codable, Equatable {
    let id: Int?
    let key: String?
    let name: String?
}

struct MembershipSubscription: Codable, Equatable {
    let id: Int?
    let status: String?
    let autoRenew: Bool?
    let renewalType: Int?
    let trial: Bool?
    let planId: Int?
    let expiresOn: String?
    let firstTrialAt: String?
    let memberId: Int?
    let networkId: Int?
    let plan: MembershipPlan?

    enum CodingKeys: String, CodingKey {
        case id, status, trial, plan
        case autoRenew = "auto_renew"
        case renewalType = "renewal_type"
        case planId = "plan_id"
        case expiresOn = "expires_on"
        case firstTrialAt = "first_trial_at"
        case memberId = "member_id"
        case networkId = "network_id"
    }

    var expiresOnDate: Date? {
        guard let expiresOn else { return nil }
        return Self.dateOnlyFormatter.date(from: expiresOn)
    }

    var firstTrialDate: Date? {
        guard let firstTrialAt else { return nil }
        if let parsed = Self.internetDateFormatter.date(from: firstTrialAt) {
            return parsed
        }
        return Self.internetDateNoFractionFormatter.date(from: firstTrialAt)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let internetDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateNoFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
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
    let trackId: Int?
    let artURL: URL?
    let duration: Int
    let startedAt: Date?
    let elapsedOverride: Int?
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
