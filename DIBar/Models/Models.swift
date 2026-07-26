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

/// One entry in the cross-network recently-played MRU list.
struct RecentStation: Codable, Identifiable, Equatable {
    let network: Network
    let channelId: Int
    let channelKey: String
    let name: String

    var id: String { "\(network.rawValue)-\(channelId)" }
}

/// A channel tagged with its network — needed wherever channels from several
/// networks appear in one list (plain channel ids can collide across networks).
struct NetworkChannel: Identifiable, Hashable {
    let network: Network
    let channel: Channel

    var id: String { "\(network.rawValue)-\(channel.id)" }
}

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
    let email: String?
    let member: AuthMember?
    let subscriptions: [MembershipSubscription]?

    struct AuthMember: Codable {
        let id: Int?
        let email: String?
    }

    enum CodingKeys: String, CodingKey {
        case listenKey = "listen_key"
        case id
        case memberId = "member_id"
        case apiKey = "api_key"
        case email
        case member
        case subscriptions
    }

    var resolvedMemberId: Int? {
        id ?? memberId ?? member?.id
    }

    var resolvedEmail: String? {
        email ?? member?.email
    }
}

// MARK: - Membership

/// Only the fields the app reads; the auth response carries more (plan,
/// renewal type, member id) that nothing consumes.
struct MembershipSubscription: Codable, Equatable {
    let status: String?
    let autoRenew: Bool?
    let trial: Bool?
    let expiresOn: String?
    let firstTrialAt: String?
    let createdAt: String?
    let networkId: Int?

    enum CodingKeys: String, CodingKey {
        case status, trial
        case autoRenew = "auto_renew"
        case expiresOn = "expires_on"
        case firstTrialAt = "first_trial_at"
        case createdAt = "created_at"
        case networkId = "network_id"
    }

    var expiresOnDate: Date? {
        guard let expiresOn else { return nil }
        return Self.dateOnlyFormatter.date(from: expiresOn)
    }

    var firstTrialDate: Date? {
        guard let firstTrialAt else { return nil }
        return Self.parseInternetDate(firstTrialAt)
    }

    var createdAtDate: Date? {
        guard let createdAt else { return nil }
        return Self.parseInternetDate(createdAt)
    }

    var startedDate: Date? {
        firstTrialDate ?? createdAtDate
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

    private static func parseInternetDate(_ raw: String) -> Date? {
        if let parsed = internetDateFormatter.date(from: raw) {
            return parsed
        }
        return internetDateNoFractionFormatter.date(from: raw)
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

/// Shared display formatting for song metadata — the one place that decides
/// how "Artist – Title" joins and how durations render.
enum TrackDisplay {
    /// "Artist – Title" (en dash), degrading to whichever side is present.
    static func artistTitle(_ artist: String, _ title: String) -> String {
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(artist) – \(title)"
    }

    /// "m:ss"
    static func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
        return TrackDisplay.artistTitle(artist, title)
    }

    /// Seconds into the track: the frozen override when the timing engine set
    /// one, else wall clock since the anchored start.
    func elapsedSeconds(at now: Date = Date()) -> Int? {
        if let elapsedOverride { return max(elapsedOverride, 0) }
        guard let startedAt else { return nil }
        return max(Int(now.timeIntervalSince(startedAt)), 0)
    }

    static func formatTime(_ seconds: Int) -> String {
        TrackDisplay.formatTime(seconds)
    }
}

/// Album art URLs are content-addressed paths on a single CDN host, so
/// history stores just the path — if the CDN ever moves, changing this
/// constant heals every stored row. URLs on an unexpected host are stored
/// in full and passed through unchanged.
enum TrackArt {
    static let cdnHost = "https://cdn-images.audioaddict.com"

    static func storagePath(from url: URL?) -> String? {
        guard let absolute = url?.absoluteString else { return nil }
        if absolute.hasPrefix(cdnHost + "/") {
            return String(absolute.dropFirst(cdnHost.count))
        }
        return absolute
    }

    static func url(fromStored stored: String?) -> URL? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("/"), !stored.hasPrefix("//") {
            return URL(string: cdnHost + stored)
        }
        return URL(string: stored)
    }

    /// The CDN resizes server-side via a `size` query — ask for pixel
    /// dimensions (2x the point size) instead of downloading full art.
    static func thumbnailURL(_ url: URL?, pixelSize: Int) -> URL? {
        guard let url else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "size", value: "\(pixelSize)x\(pixelSize)")]
        return components?.url ?? url
    }
}

// MARK: - Channel Filters

/// One entry of /channel_filters; only the channel list is consumed.
struct ChannelFilter: Codable {
    let channels: [Channel]?
}
