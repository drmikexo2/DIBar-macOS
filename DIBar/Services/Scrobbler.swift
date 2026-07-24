import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "Scrobbler")

/// Coordinates scrobbling to Last.fm on top of the history
/// recorder's segment stream: accumulates per-song listen time across
/// pause/sleep splits, applies the standard eligibility rule, and drains a
/// persistent queue so offline listens survive.
@Observable
@MainActor
final class Scrobbler {
    private let recorder: HistoryRecorder

    // Connections (tokens live in UserDefaults by design)
    private(set) var lastFMSessionKey: String? = Prefs.read(key: "lastfm_session_key")
    private(set) var lastFMUsername: String? = Prefs.read(key: "lastfm_username")

    /// Set when Last.fm reports the session invalid (error 9).
    var lastFMNeedsReconnect = false
    /// Token from getToken, held between "Connect" and "Finish connecting".
    var lastFMPendingToken: String?
    var connectionError: String?

    var lastFMConnected: Bool { lastFMSessionKey != nil }

    // Accumulation across segments of the same song
    private var currentKey: String?
    private var currentArtist = ""
    private var currentTitle = ""
    private var currentDuration = 0
    private var currentStartedAt: Date?
    private var accumulatedSeconds: TimeInterval = 0

    private var lastNowPlayingKey: String?
    private var flushTimer: Timer?
    private var flushInFlight = false

    init(recorder: HistoryRecorder) {
        self.recorder = recorder
    }

    func start() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        flush()
    }

    // MARK: - Recorder hooks

    func trackStarted(artist: String, title: String, duration: Int) {
        guard lastFMConnected, isScrobblable(artist: artist, title: title) else { return }
        let key = songKey(artist: artist, title: title)
        guard key != lastNowPlayingKey else { return }
        lastNowPlayingKey = key

        // Now-playing is best-effort: failures are ignored, never queued.
        if let sessionKey = lastFMSessionKey {
            Task {
                try? await LastFMClient.updateNowPlaying(
                    artist: artist, title: title, duration: duration, sessionKey: sessionKey
                )
            }
        }
    }

    func segmentClosed(
        artist: String, title: String, duration: Int,
        startedAt: Date, endedAt: Date, reason: HistoryStore.EndReason
    ) {
        let key = songKey(artist: artist, title: title)

        if key != currentKey {
            finalizeCurrent()
            currentKey = key
            currentArtist = artist
            currentTitle = title
            currentDuration = duration
            currentStartedAt = startedAt
            accumulatedSeconds = 0
        }
        // Late enrichment can improve what we hold
        if currentDuration == 0 { currentDuration = duration }
        accumulatedSeconds += endedAt.timeIntervalSince(startedAt)

        switch reason {
        case .pause, .sleep, .stall:
            // The same song may resume — keep accumulating
            break
        case .trackChange, .channelSwitch, .stop, .quit, .crash:
            finalizeCurrent()
        }
    }

    // MARK: - Accumulation & eligibility

    private func finalizeCurrent() {
        defer {
            currentKey = nil
            accumulatedSeconds = 0
            currentStartedAt = nil
        }
        guard let startedAt = currentStartedAt,
              isScrobblable(artist: currentArtist, title: currentTitle)
        else { return }

        // Standard rule: half the track, or 4 minutes of a long/unknown one.
        let halfDone = currentDuration > 30 && accumulatedSeconds >= Double(currentDuration) / 2
        let longEnough = accumulatedSeconds >= 240
        guard halfDone || longEnough else { return }
        guard lastFMConnected else { return }

        recorder.enqueueScrobble(
            listenedAt: startedAt,
            artist: currentArtist,
            title: currentTitle,
            duration: currentDuration > 0 ? currentDuration : nil,
            network: "",
            channelName: ""
        )
        log.info("queued scrobble: \(self.currentArtist, privacy: .public) – \(self.currentTitle, privacy: .public)")
        flush()
    }

    /// Jingles and ads: no artist (ICY jingles come through title-only), the
    /// artist matching the station branding, or obvious ad/URL patterns.
    private func isScrobblable(artist: String, title: String) -> Bool {
        guard !artist.isEmpty, !title.isEmpty, title != "Loading..." else { return false }
        let combined = "\(artist) \(title)".lowercased()
        let adPatterns = ["advert", "jingle", "di.fm", "radiotunes", "jazzradio", "rockradio", "zenradio", "classicalradio", ".com/"]
        return !adPatterns.contains { combined.contains($0) }
    }

    private func songKey(artist: String, title: String) -> String {
        "\(HistoryRecorder.mergeKey(artist))|\(HistoryRecorder.mergeKey(title))"
    }

    // MARK: - Queue flush

    func flush() {
        guard lastFMConnected, !flushInFlight else { return }
        flushInFlight = true
        recorder.maintainScrobbleQueue()
        Task {
            defer { flushInFlight = false }
            await flushLastFM()
        }
    }

    private func flushLastFM() async {
        guard let sessionKey = lastFMSessionKey else { return }
        let batch = recorder.pendingScrobbles(service: .lastfm)
        guard !batch.isEmpty else { return }
        do {
            try await LastFMClient.scrobble(batch, sessionKey: sessionKey)
            recorder.markScrobblesSent(ids: batch.map(\.id), service: .lastfm)
            log.info("last.fm: sent \(batch.count) scrobble(s)")
        } catch LastFMError.invalidSession {
            disconnectLastFM(needsReconnect: true)
        } catch {
            recorder.bumpScrobbleAttempts(ids: batch.map(\.id))
            log.error("last.fm flush failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Account connections

    /// Step 1 of the Last.fm web flow: fetch a token and open the browser on
    /// the authorize page. The UI then offers "Finish connecting".
    func connectLastFM() {
        connectionError = nil
        Task {
            do {
                let token = try await LastFMClient.getToken()
                lastFMPendingToken = token
                NSWorkspace.shared.open(LastFMClient.authorizationURL(token: token))
            } catch {
                connectionError = "Last.fm: \(error.localizedDescription)"
            }
        }
    }

    /// Step 2, after the user authorized in the browser.
    func finishLastFMConnect() {
        guard let token = lastFMPendingToken else { return }
        connectionError = nil
        Task {
            do {
                let session = try await LastFMClient.getSession(token: token)
                lastFMSessionKey = session.key
                lastFMUsername = session.username
                lastFMPendingToken = nil
                lastFMNeedsReconnect = false
                Prefs.save(key: "lastfm_session_key", value: session.key)
                Prefs.save(key: "lastfm_username", value: session.username)
                flush()
            } catch {
                connectionError = "Last.fm: authorize in the browser first, then try again"
            }
        }
    }

    func disconnectLastFM(needsReconnect: Bool = false) {
        lastFMSessionKey = nil
        lastFMUsername = nil
        lastFMPendingToken = nil
        lastFMNeedsReconnect = needsReconnect
        Prefs.delete(key: "lastfm_session_key")
        Prefs.delete(key: "lastfm_username")
    }
}
