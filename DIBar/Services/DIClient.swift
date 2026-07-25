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

    static func fetchChannels(listenKey: String, quality: StreamQuality, network: Network) async throws -> [Channel] {
        guard let url = URL(string: "\(network.apiBaseURL)/channel_filters") else {
            throw DIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DIClientError.httpError(code)
        }

        log.info("channels(\(network.rawValue)): HTTP \(http.statusCode), \(data.count) bytes")

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
        let urlStr = "\(network.apiBaseURL)/members/1/favorites/channels?api_key=\(urlEncode(apiKey))"
        guard let url = URL(string: urlStr) else { throw DIClientError.invalidURL }

        log.info("favorites(\(network.rawValue)): GET")

        var request = URLRequest(url: url)
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        log.info("favorites(\(network.rawValue)): HTTP \(http?.statusCode ?? 0), \(data.count) bytes")

        guard let http, (200...299).contains(http.statusCode) else {
            log.error("favorites(\(network.rawValue)): HTTP error \(http?.statusCode ?? 0)")
            throw DIClientError.httpError(http?.statusCode ?? 0)
        }

        return data
    }

    /// Replace the member's favorites with the given ordered channel list.
    /// The endpoint has bulk-replace semantics (verified against the live API),
    /// so callers must GET-merge-POST rather than posting a single change.
    static func setFavorites(channelIds: [Int], memberId: Int, apiKey: String, network: Network) async throws {
        let urlStr = "\(network.apiBaseURL)/members/\(memberId)/favorites/channels?api_key=\(urlEncode(apiKey))"
        guard let url = URL(string: urlStr) else { throw DIClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["favorites": channelIds.enumerated().map { ["channel_id": $1, "position": $0] }]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        log.info("setFavorites(\(network.rawValue)): POST \(channelIds.count) favorites, HTTP \(http?.statusCode ?? 0)")

        guard let http, (200...299).contains(http.statusCode) else {
            throw DIClientError.httpError(http?.statusCode ?? 0)
        }
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
        let urlStr = "\(network.apiBaseURL)/\(path)?api_key=\(urlEncode(apiKey))"
        guard let url = URL(string: urlStr) else { throw DIClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        log.info("vote(\(network.rawValue)): \(method, privacy: .public) \(path, privacy: .public) HTTP \(http?.statusCode ?? 0)")

        guard let http, (200...299).contains(http.statusCode) else {
            throw DIClientError.httpError(http?.statusCode ?? 0)
        }
    }

    // MARK: - Track History (Now Playing)

    static func fetchCurrentTrack(channelId: Int, network: Network) async throws -> TrackHistoryItem? {
        guard let url = URL(string: "\(network.apiBaseURL)/track_history/channel/\(channelId)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, _) = try await URLSession.shared.data(for: request)

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
        guard let url = URL(string: "\(network.apiBaseURL)/members/authenticate") else {
            throw DIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DIClientError.networkError(URLError(.badServerResponse))
        }

        log.info("auth: HTTP \(http.statusCode)")

        if http.statusCode == 403 || http.statusCode == 401 {
            throw DIClientError.authFailed
        }

        guard (200...299).contains(http.statusCode) else {
            throw DIClientError.httpError(http.statusCode)
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
