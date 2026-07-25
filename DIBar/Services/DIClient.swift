import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "DIClient")

enum DIClientError: LocalizedError {
    case authFailed
    case httpError(Int)
    case networkError(Error)
    case decodingError(Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .authFailed: "Invalid email or password"
        case .httpError(let code): "Server error (\(code))"
        case .networkError(let err): "Network error: \(err.localizedDescription)"
        case .decodingError(let err): "Data error: \(err.localizedDescription)"
        case .invalidURL: "Invalid URL"
        }
    }
}

enum DIClient {
    private static let basicAuth = "Basic ZXBoZW1lcm9uOmRheWVpcGgwbmVAcHA="

    // MARK: - Request plumbing

    /// Build and run an authorized request, returning the body and status.
    private static func performRaw(
        _ urlString: String,
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil
    ) async throws -> (data: Data, status: Int) {
        guard let url = URL(string: urlString) else { throw DIClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        if let cachePolicy {
            request.cachePolicy = cachePolicy
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DIClientError.networkError(URLError(.badServerResponse))
        }
        return (data, http.statusCode)
    }

    /// performRaw + the standard non-2xx-throws policy.
    private static func perform(
        _ urlString: String,
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil
    ) async throws -> Data {
        let (data, status) = try await performRaw(
            urlString, method: method, contentType: contentType,
            body: body, cachePolicy: cachePolicy
        )
        guard (200...299).contains(status) else {
            throw DIClientError.httpError(status)
        }
        return data
    }

    // MARK: - Authenticate

    static func authenticate(email: String, password: String) async throws -> AuthResponse {
        let body = "username=\(formEncode(email))&password=\(formEncode(password))"
        return try await authenticateMember(body: body, network: .di)
    }

    static func fetchMembership(apiKey: String) async throws -> AuthResponse {
        let body = "api_key=\(formEncode(apiKey))"
        return try await authenticateMember(body: body, network: .di)
    }

    // MARK: - Fetch Channels

    static func fetchChannels(network: Network) async throws -> [Channel] {
        let data = try await perform("\(network.apiBaseURL)/channel_filters")

        log.info("channels(\(network.rawValue)): \(data.count) bytes")

        do {
            let filters = try JSONDecoder().decode([ChannelFilter].self, from: data)
            var channels: [Channel] = []
            for filter in filters {
                if let filterChannels = filter.channels {
                    channels.append(contentsOf: filterChannels)
                }
            }
            var seen = Set<Int>()
            channels = channels.filter { seen.insert($0.id).inserted }
            log.info("channels(\(network.rawValue)): \(channels.count) unique channels")
            return channels
        } catch {
            throw DIClientError.decodingError(error)
        }
    }

    // MARK: - Fetch Favorites

    static func fetchFavorites(apiKey: String, network: Network) async throws -> Set<Int> {
        let data = try await favoritesData(apiKey: apiKey, network: network)
        return extractChannelIds(from: data)
    }

    /// Favorites in server order (by position). Used for the read-merge-write
    /// cycle in setFavorites, where order must be preserved.
    static func fetchFavoritesOrdered(apiKey: String, network: Network) async throws -> [Int] {
        let data = try await favoritesData(apiKey: apiKey, network: network)
        if let favorites = try? JSONDecoder().decode([FavoriteChannel].self, from: data) {
            return favorites
                .sorted { ($0.position ?? .max) < ($1.position ?? .max) }
                .compactMap(\.resolvedChannelId)
        }
        return Array(extractChannelIds(from: data)).sorted()
    }

    private static func favoritesData(apiKey: String, network: Network) async throws -> Data {
        let data = try await perform(
            "\(network.apiBaseURL)/members/1/favorites/channels?api_key=\(urlEncode(apiKey))"
        )
        log.info("favorites(\(network.rawValue)): \(data.count) bytes")
        return data
    }

    /// Replace the member's favorites with the given ordered channel list.
    /// The endpoint has bulk-replace semantics (verified against the live API),
    /// so callers must GET-merge-POST rather than posting a single change.
    static func setFavorites(channelIds: [Int], memberId: Int, apiKey: String, network: Network) async throws {
        let payload = ["favorites": channelIds.enumerated().map { ["channel_id": $1, "position": $0] }]
        _ = try await perform(
            "\(network.apiBaseURL)/members/\(memberId)/favorites/channels?api_key=\(urlEncode(apiKey))",
            method: "POST",
            contentType: "application/json",
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        log.info("setFavorites(\(network.rawValue)): POST \(channelIds.count) favorites ok")
    }

    /// Walk any JSON structure and extract all "channel_id" integer values found
    private static func extractChannelIds(from data: Data) -> Set<Int> {
        var channelIds = Set<Int>()

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            log.error("favorites: not valid JSON")
            return channelIds
        }

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let cid = dict["channel_id"] as? Int {
                    channelIds.insert(cid)
                }
                if let channel = dict["channel"] as? [String: Any], let cid = channel["id"] as? Int {
                    channelIds.insert(cid)
                }
                for (_, value) in dict {
                    walk(value)
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    walk(item)
                }
            }
        }

        walk(json)

        log.info("favorites: extracted \(channelIds.count) channel IDs: \(channelIds.sorted())")

        return channelIds
    }

    // MARK: - Voting

    /// Cast an up/down vote on a track (shape verified against the live API:
    /// POST /tracks/{id}/vote/{channel}/up|down bumps the community count).
    static func castVote(trackId: Int, channelId: Int, up: Bool, apiKey: String, network: Network) async throws {
        try await voteRequest(
            method: "POST",
            path: "tracks/\(trackId)/vote/\(channelId)/\(up ? "up" : "down")",
            apiKey: apiKey,
            network: network
        )
    }

    static func removeVote(trackId: Int, channelId: Int, apiKey: String, network: Network) async throws {
        try await voteRequest(
            method: "DELETE",
            path: "tracks/\(trackId)/vote/\(channelId)",
            apiKey: apiKey,
            network: network
        )
    }

    private static func voteRequest(method: String, path: String, apiKey: String, network: Network) async throws {
        _ = try await perform(
            "\(network.apiBaseURL)/\(path)?api_key=\(urlEncode(apiKey))",
            method: method
        )
        log.info("vote(\(network.rawValue)): \(method, privacy: .public) \(path, privacy: .public) ok")
    }

    // MARK: - Track History (Now Playing)

    static func fetchCurrentTrack(channelId: Int, network: Network) async throws -> TrackHistoryItem? {
        let data = try await perform(
            "\(network.apiBaseURL)/track_history/channel/\(channelId)",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        let items = try? JSONDecoder().decode([TrackHistoryItem].self, from: data)
        return items?.first
    }

    // MARK: - Stream URL

    static func streamURL(channelKey: String, listenKey: String, quality: StreamQuality, network: Network) -> URL? {
        URL(string: "\(network.listenBaseURL)/\(quality.rawValue)/\(urlEncode(channelKey)).pls?listen_key=\(urlEncode(listenKey))")
    }

    // MARK: - Helpers

    private static func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func authenticateMember(body: String, network: Network) async throws -> AuthResponse {
        let (data, status) = try await performRaw(
            "\(network.apiBaseURL)/members/authenticate",
            method: "POST",
            contentType: "application/x-www-form-urlencoded",
            body: body.data(using: .utf8)
        )

        log.info("auth: HTTP \(status)")

        if status == 403 || status == 401 {
            throw DIClientError.authFailed
        }

        guard (200...299).contains(status) else {
            throw DIClientError.httpError(status)
        }

        do {
            let result = try JSONDecoder().decode(AuthResponse.self, from: data)
            log.info("auth decoded: resolvedMemberId=\(result.resolvedMemberId?.description ?? "nil")")
            return result
        } catch {
            log.error("auth decode error: \(error)")
            throw DIClientError.decodingError(error)
        }
    }
}
