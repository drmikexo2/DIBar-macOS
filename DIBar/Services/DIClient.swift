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
    static let baseURL = "https://api.audioaddict.com/v1/di"
    static let listenBaseURL = "https://listen.di.fm"
    private static let basicAuth = "Basic ZXBoZW1lcm9uOmRheWVpcGgwbmVAcHA="

    // MARK: - Authenticate

    static func authenticate(email: String, password: String) async throws -> AuthResponse {
        let body = "username=\(formEncode(email))&password=\(formEncode(password))"
        return try await authenticateMember(body: body)
    }

    static func fetchMembership(apiKey: String) async throws -> AuthResponse {
        let body = "api_key=\(formEncode(apiKey))"
        return try await authenticateMember(body: body)
    }

    // MARK: - Fetch Channels

    static func fetchChannels(listenKey: String, quality: StreamQuality) async throws -> [Channel] {
        guard let url = URL(string: "\(baseURL)/channel_filters") else {
            throw DIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DIClientError.httpError(code)
        }

        log.info("channels: HTTP \(http.statusCode), \(data.count) bytes")

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
            log.info("channels: \(channels.count) unique channels from channel_filters")
            return channels
        } catch {
            throw DIClientError.decodingError(error)
        }
    }

    // MARK: - Fetch Favorites

    static func fetchFavorites(apiKey: String) async throws -> Set<Int> {
        let urlStr = "\(baseURL)/members/1/favorites/channels?api_key=\(urlEncode(apiKey))"
        guard let url = URL(string: urlStr) else { return [] }

        log.info("favorites: GET /members/1/favorites/channels?api_key=***")

        var request = URLRequest(url: url)
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        log.info("favorites: HTTP \(http?.statusCode ?? 0), \(data.count) bytes")
        if let raw = String(data: data, encoding: .utf8) {
            log.info("favorites raw (500): \(raw.prefix(500))")
        }

        guard let http, (200...299).contains(http.statusCode) else {
            log.error("favorites: HTTP error \(http?.statusCode ?? 0)")
            return []
        }

        return extractChannelIds(from: data)
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

    // MARK: - Track History (Now Playing)

    static func fetchCurrentTrack(channelId: Int) async throws -> TrackHistoryItem? {
        guard let url = URL(string: "\(baseURL)/track_history/channel/\(channelId)") else {
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

    static func streamURL(channelKey: String, listenKey: String, quality: StreamQuality) -> URL? {
        URL(string: "\(listenBaseURL)/\(quality.rawValue)/\(urlEncode(channelKey)).pls?listen_key=\(urlEncode(listenKey))")
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

    private static func extractTopLevelKeys(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Array(json.keys).sorted()
    }

    private static func authenticateMember(body: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/members/authenticate") else {
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
        log.info("auth raw keys: \(extractTopLevelKeys(from: data))")
        if let raw = String(data: data, encoding: .utf8) {
            log.info("auth raw (500): \(raw.prefix(500))")
        }

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
