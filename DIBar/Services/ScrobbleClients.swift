import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.dibar", category: "ScrobbleClients")

// MARK: - Last.fm

enum LastFMError: Error {
    case notConfigured
    case httpError(Int)
    case apiError(code: Int, message: String)
    /// Error 9 — the session key was revoked; the user must reconnect.
    case invalidSession
}

/// Minimal Last.fm client: desktop web-auth flow plus the two scrobbling
/// calls. Requests are signed with MD5 as the API mandates.
enum LastFMClient {
    /// Developer credentials — the app's registered Last.fm API account.
    static let apiKey = Secrets.lastFMAPIKey
    static let sharedSecret = Secrets.lastFMSharedSecret

    static var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }

    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    struct Session {
        let key: String
        let username: String
    }

    // MARK: Auth (web flow: token → browser authorize → session)

    static func getToken() async throws -> String {
        let json = try await call(["method": "auth.getToken"], signed: true, post: false)
        guard let token = json["token"] as? String else {
            throw LastFMError.apiError(code: -1, message: "no token in response")
        }
        return token
    }

    static func authorizationURL(token: String) -> URL {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
    }

    static func getSession(token: String) async throws -> Session {
        let json = try await call(["method": "auth.getSession", "token": token], signed: true, post: false)
        guard let session = json["session"] as? [String: Any],
              let key = session["key"] as? String,
              let name = session["name"] as? String
        else {
            throw LastFMError.apiError(code: -1, message: "no session in response")
        }
        return Session(key: key, username: name)
    }

    // MARK: Scrobbling

    static func updateNowPlaying(artist: String, title: String, duration: Int?, sessionKey: String) async throws {
        var params = [
            "method": "track.updateNowPlaying",
            "artist": artist,
            "track": title,
            "sk": sessionKey,
        ]
        if let duration, duration > 0 {
            params["duration"] = String(duration)
        }
        _ = try await call(params, signed: true, post: true)
    }

    static func scrobble(_ batch: [HistoryStore.PendingScrobble], sessionKey: String) async throws {
        guard !batch.isEmpty else { return }
        var params = [
            "method": "track.scrobble",
            "sk": sessionKey,
        ]
        for (index, item) in batch.enumerated() {
            params["artist[\(index)]"] = item.artist
            params["track[\(index)]"] = item.title
            params["timestamp[\(index)]"] = String(Int(item.listenedAt.timeIntervalSince1970))
            if let duration = item.duration, duration > 0 {
                params["duration[\(index)]"] = String(duration)
            }
        }
        _ = try await call(params, signed: true, post: true)
    }

    // MARK: Plumbing

    private static func call(_ params: [String: String], signed: Bool, post: Bool) async throws -> [String: Any] {
        guard isConfigured else { throw LastFMError.notConfigured }

        var allParams = params
        allParams["api_key"] = apiKey
        if signed {
            allParams["api_sig"] = signature(for: allParams)
        }
        // format is excluded from the signature per the API docs
        allParams["format"] = "json"

        var components = URLComponents()
        components.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }

        var request: URLRequest
        if post {
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        } else {
            var getComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            getComponents.queryItems = components.queryItems
            request = URLRequest(url: getComponents.url!)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LastFMError.httpError(-1) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let errorCode = json["error"] as? Int {
            let message = json["message"] as? String ?? "unknown"
            log.error("last.fm error \(errorCode): \(message, privacy: .public)")
            if errorCode == 9 { throw LastFMError.invalidSession }
            throw LastFMError.apiError(code: errorCode, message: message)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LastFMError.httpError(http.statusCode)
        }
        return json
    }

    /// md5(sorted key+value pairs concatenated, then the shared secret).
    private static func signature(for params: [String: String]) -> String {
        let concatenated = params.keys.sorted()
            .map { "\($0)\(params[$0] ?? "")" }
            .joined() + sharedSecret
        let digest = Insecure.MD5.hash(data: Data(concatenated.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
