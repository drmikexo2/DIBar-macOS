import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "HistoryRecorder")

/// Records listening history by diffing a once-per-second snapshot of the
/// player's public state — no hooks inside AudioPlayer's timing engine.
@Observable
@MainActor
final class HistoryRecorder {
    private struct Snapshot: Equatable {
        var isPlaying: Bool
        var network: String?
        var channelId: Int?
        var channelKey: String?
        var channelName: String?
        var identityToken: String?
        var artist: String
        var title: String
        var trackId: Int?
    }

    private let player: AudioPlayer
    private var store: HistoryStore?
    private var timer: Timer?
    private var enabled = true

    private var openSegmentId: Int64?
    private var openSegmentStartedAt: Date?
    private var lastSnapshot = Snapshot(
        isPlaying: false, network: nil, channelId: nil, channelKey: nil,
        channelName: nil, identityToken: nil, artist: "", title: "", trackId: nil
    )
    private var lastTickAt: Date?
    private var tickCount = 0

    /// Listening totals, refreshed together every ~15s and on segment close
    /// so they can never disagree in the UI.
    private(set) var todayListenedSeconds: TimeInterval = 0
    private(set) var allTimeListenedSeconds: TimeInterval = 0

    init(player: AudioPlayer) {
        self.player = player
    }

    func start() {
        guard timer == nil else { return }
        if let url = HistoryStore.defaultURL() {
            store = HistoryStore(url: url)
        }
        store?.recoverDanglingSegments()
        refreshTodayTotal()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        enabled = isEnabled
        if !isEnabled {
            closeOpenSegment(at: Date(), reason: .stop)
        }
    }

    func appWillTerminate() {
        closeOpenSegment(at: Date(), reason: .quit)
        store?.checkpointAndClose()
        store = nil
    }

    // MARK: - History window queries

    func recentListens(limit: Int = 500) -> [HistoryStore.ListenEntry] {
        // Fetch extra raw segments since merging shrinks the list
        Self.mergingAdjacent(store?.recentListens(limit: limit * 2) ?? [])
    }

    /// Collapse back-to-back segments of the same song on the same station
    /// (splits caused by pauses, crashes, or stream restarts) into one entry.
    /// Distinct plays separated by more than `maxGap` stay separate.
    static func mergingAdjacent(
        _ entries: [HistoryStore.ListenEntry],
        maxGap: TimeInterval = 300
    ) -> [HistoryStore.ListenEntry] {
        var merged: [HistoryStore.ListenEntry] = []
        for entry in entries { // newest first: `entry` is older than `merged.last`
            if let newer = merged.last,
               mergeKey(newer.artist) == mergeKey(entry.artist),
               mergeKey(newer.title) == mergeKey(entry.title),
               newer.network == entry.network,
               newer.channelName == entry.channelName,
               newer.startedAt.timeIntervalSince(entry.startedAt.addingTimeInterval(entry.duration)) <= maxGap {
                merged[merged.count - 1] = HistoryStore.ListenEntry(
                    id: newer.id,
                    startedAt: entry.startedAt,
                    duration: newer.duration + entry.duration,
                    network: newer.network,
                    channelName: newer.channelName,
                    artist: newer.artist,
                    title: newer.title,
                    vote: newer.vote ?? entry.vote
                )
            } else {
                merged.append(entry)
            }
        }
        return merged
    }

    /// Canonical form for comparing song metadata across sources: ICY and the
    /// API render the same title with different quote characters and spacing.
    static func mergeKey(_ text: String) -> String {
        // backtick, acute, left/right single curly quotes, reversed quote,
        // modifier apostrophe, prime — all fold to a straight apostrophe
        let quoteVariants = "`´\u{2018}\u{2019}\u{201B}\u{02BC}\u{2032}"
        let folded = text.lowercased().map { char -> Character in
            quoteVariants.contains(char) ? "'" : char
        }
        return String(folded)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    func voteEntries(vote: Int, limit: Int = 500) -> [HistoryStore.VoteEntry] {
        store?.voteEntries(vote: vote, limit: limit) ?? []
    }

    // MARK: - Song votes (explicit user actions; recorded regardless of the
    // listening-history toggle)

    func vote(forTrackId trackId: Int) -> Int? {
        store?.vote(forTrackId: trackId)
    }

    func recordVote(trackId: Int, vote: Int, artist: String, title: String, network: String, channelId: Int, channelName: String) {
        store?.setVote(
            trackId: trackId, vote: vote, artist: artist, title: title,
            network: network, channelId: channelId, channelName: channelName,
            at: Date(), synced: false
        )
    }

    func markVoteSynced(trackId: Int) {
        store?.markVoteSynced(trackId: trackId)
    }

    func clearVote(trackId: Int) {
        store?.clearVote(trackId: trackId)
    }

    // MARK: - Tick

    private func tick() {
        guard let store else { return }
        let now = Date()
        tickCount += 1

        // System sleep suspends timers; a long gap means the audio stopped —
        // close at the last heartbeat rather than counting the sleep.
        if let lastTick = lastTickAt, now.timeIntervalSince(lastTick) > 30, openSegmentId != nil {
            closeOpenSegment(at: lastTick, reason: .sleep)
        }
        lastTickAt = now

        let track = player.currentTrack
        let snapshot = Snapshot(
            isPlaying: player.isPlaying,
            network: player.currentNetwork?.rawValue,
            channelId: player.currentChannel?.id,
            channelKey: player.currentChannel?.key,
            channelName: player.currentChannel?.name,
            identityToken: player.currentTrackIdentityToken,
            artist: sanitize(track?.artist),
            title: sanitize(track?.title),
            trackId: track?.trackId
        )
        defer { lastSnapshot = snapshot }

        // Close conditions
        if openSegmentId != nil {
            if !enabled {
                closeOpenSegment(at: now, reason: .stop)
            } else if !snapshot.isPlaying {
                closeOpenSegment(at: now, reason: snapshot.channelId == nil ? .stop : .pause)
            } else if snapshot.channelId != lastSnapshot.channelId {
                closeOpenSegment(at: now, reason: .channelSwitch)
            } else if let old = lastSnapshot.identityToken, let new = snapshot.identityToken, old != new {
                closeOpenSegment(at: now, reason: .trackChange)
            } else if lastSnapshot.identityToken != nil && snapshot.identityToken == nil {
                // Stream restart (e.g. quality change) resets the token
                closeOpenSegment(at: now, reason: .channelSwitch)
            }
        }

        // Open condition — even before track metadata arrives, so buffering
        // and jingles count toward station time.
        if openSegmentId == nil, enabled, snapshot.isPlaying,
           let network = snapshot.network,
           let channelId = snapshot.channelId,
           let channelKey = snapshot.channelKey,
           let channelName = snapshot.channelName {
            openSegmentId = store.openSegment(
                startedAt: now,
                network: network,
                channelId: channelId,
                channelKey: channelKey,
                channelName: channelName,
                artist: snapshot.artist,
                title: snapshot.title,
                trackId: snapshot.trackId
            )
            openSegmentStartedAt = now
            log.info("segment open: \(channelName, privacy: .public) [\(network, privacy: .public)]")
        } else if let id = openSegmentId {
            // Enrichment: same segment, better metadata (first ICY/API arrival
            // or the API filling trackId after an ICY title flip)
            if snapshot.artist != lastSnapshot.artist
                || snapshot.title != lastSnapshot.title
                || snapshot.trackId != lastSnapshot.trackId {
                store.enrich(id: id, artist: snapshot.artist, title: snapshot.title, trackId: snapshot.trackId)
            }
            if tickCount % 5 == 0 {
                store.heartbeat(id: id, at: now)
            }
        }

        if tickCount % 15 == 0 {
            refreshTodayTotal()
        }
    }

    private func closeOpenSegment(at date: Date, reason: HistoryStore.EndReason) {
        guard let id = openSegmentId else { return }
        openSegmentId = nil
        // Sub-second segments are poll-tick noise, not listening
        if let startedAt = openSegmentStartedAt, date.timeIntervalSince(startedAt) < 1.0 {
            store?.delete(id: id)
        } else {
            store?.close(id: id, at: date, reason: reason)
            log.info("segment close: \(reason.rawValue, privacy: .public)")
        }
        openSegmentStartedAt = nil
        refreshTodayTotal()
    }

    private func refreshTodayTotal() {
        guard let store else { return }
        todayListenedSeconds = store.listenedSeconds(since: Calendar.current.startOfDay(for: Date()))
        allTimeListenedSeconds = store.listenedSeconds(since: Date(timeIntervalSince1970: 0))
    }

    private func sanitize(_ text: String?) -> String {
        guard let text, text != "Loading..." else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
