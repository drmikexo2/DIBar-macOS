import Foundation
import Observation
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
        var trackDuration: Int
        var artPath: String?
    }

    private let player: AudioPlayer
    private var store: HistoryStore?
    private var timer: Timer?
    private var enabled = true

    private var openSegmentId: Int64?
    private var openSegmentStartedAt: Date?
    private var openSegmentTrackId: Int?
    private var lastSnapshot = Snapshot(
        isPlaying: false, network: nil, channelId: nil, channelKey: nil,
        channelName: nil, identityToken: nil, artist: "", title: "", trackId: nil,
        trackDuration: 0, artPath: nil
    )

    // Scrobbling hooks, set by AppState. Fired from the same tick diffing —
    // the scrobbler stays as decoupled from AudioPlayer as this recorder is.
    var onTrackStarted: ((_ artist: String, _ title: String, _ duration: Int) -> Void)?
    var onSegmentClosed: ((
        _ artist: String, _ title: String, _ duration: Int,
        _ startedAt: Date, _ endedAt: Date, _ reason: HistoryStore.EndReason
    ) -> Void)?
    private var lastTickAt: Date?
    private var tickCount = 0
    private var reconnectingTicks = 0
    private var isStarted = false

    /// Listening totals, refreshed together every ~15s and on segment close
    /// so they can never disagree in the UI. The all-time total is a cached
    /// sum of closed segments plus the open segment's elapsed time — the
    /// full-table scan behind it runs once per launch, not per refresh.
    private(set) var todayListenedSeconds: TimeInterval = 0
    private(set) var allTimeListenedSeconds: TimeInterval = 0
    private var allTimeClosedBase: TimeInterval = 0
    #if DEBUG
    private var verifiedAllTimeBase = false
    #endif

    init(player: AudioPlayer) {
        self.player = player
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if let url = HistoryStore.defaultURL() {
            store = HistoryStore(url: url)
        }
        store?.recoverDanglingSegments()
        allTimeClosedBase = store?.closedListenedSeconds() ?? 0
        refreshTodayTotal()
        syncTimerToPlayback()
        observePlayback()
    }

    /// The 1s diff tick only matters while the player is playing; when
    /// playback stops, one final tick closes the open segment through the
    /// normal path, then the timer goes quiet until the next play.
    private func observePlayback() {
        withObservationTracking {
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncTimerToPlayback()
                self.observePlayback()
            }
        }
    }

    private func syncTimerToPlayback() {
        if player.isPlaying {
            guard timer == nil else { return }
            lastTickAt = nil // a stale gap from the quiet period is not sleep
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 0.3
            tick()
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
            tick()
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
        // The history window shows the totals alongside this list; with the
        // tick quiet while idle, refresh here so day rollover can't go stale.
        refreshTodayTotal()
        // Fetch extra raw segments since merging shrinks the list
        return Self.mergingAdjacent(store?.recentListens(limit: limit * 2) ?? [])
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
               newer.network == entry.network,
               newer.channelName == entry.channelName,
               newer.startedAt.timeIntervalSince(entry.startedAt.addingTimeInterval(entry.duration)) <= maxGap,
               sameTrack(newer, entry) {
                // Prefer canonical metadata: the side that knows its trackId
                // carries the API name, not an ICY variant. Newer wins a tie.
                let canonical = (newer.trackId != nil || entry.trackId == nil) ? newer : entry
                merged[merged.count - 1] = HistoryStore.ListenEntry(
                    id: newer.id,
                    startedAt: entry.startedAt,
                    duration: newer.duration + entry.duration,
                    network: newer.network,
                    channelName: newer.channelName,
                    artist: canonical.artist,
                    title: canonical.title,
                    trackId: canonical.trackId,
                    vote: newer.vote ?? entry.vote,
                    artURL: newer.artURL ?? entry.artURL
                )
            } else {
                merged.append(entry)
            }
        }
        return merged
    }

    /// Canonical form for comparing song metadata across sources; see
    /// TrackMatching. Kept as a pass-through for existing callers (Scrobbler).
    static func mergeKey(_ text: String) -> String {
        TrackMatching.mergeKey(text)
    }

    /// Whether two history entries record the same track. Track ids decide
    /// when both sides have one (two DI tracks can share a base title);
    /// otherwise fall back to names, bridging ICY remix suffixes.
    private static func sameTrack(_ a: HistoryStore.ListenEntry, _ b: HistoryStore.ListenEntry) -> Bool {
        if let idA = a.trackId, let idB = b.trackId { return idA == idB }
        if mergeKey(a.artist) == mergeKey(b.artist), mergeKey(a.title) == mergeKey(b.title) { return true }
        return TrackMatching.sameSong(artistA: a.artist, titleA: a.title, artistB: b.artist, titleB: b.title)
    }

    func voteEntries(vote: Int, limit: Int = 500) -> [HistoryStore.VoteEntry] {
        store?.voteEntries(vote: vote, limit: limit) ?? []
    }

    // MARK: - Song votes (explicit user actions; recorded regardless of the
    // listening-history toggle)

    func vote(forTrackId trackId: Int) -> Int? {
        store?.vote(forTrackId: trackId)
    }

    func recordVote(trackId: Int, vote: Int, artist: String, title: String, network: String, channelId: Int, channelName: String, artPath: String?) {
        store?.setVote(
            trackId: trackId, vote: vote, artist: artist, title: title,
            network: network, channelId: channelId, channelName: channelName,
            at: Date(), synced: false, artPath: artPath
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

        // Short rebuffers stay inside the open segment; only a reconnect that
        // drags on (>10s) closes it as a stall.
        let isReconnecting = player.isRecovering
        reconnectingTicks = isReconnecting ? reconnectingTicks + 1 : 0

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
            trackId: track?.trackId,
            trackDuration: track?.duration ?? 0,
            artPath: TrackArt.storagePath(from: track?.artURL)
        )
        defer { lastSnapshot = snapshot }

        // Now-playing hook: a new track identity, or metadata first arriving
        // for the current one.
        let hadMetadata = !(lastSnapshot.artist.isEmpty && lastSnapshot.title.isEmpty)
        let hasMetadata = !(snapshot.artist.isEmpty && snapshot.title.isEmpty)
        if snapshot.isPlaying, hasMetadata,
           snapshot.identityToken != lastSnapshot.identityToken || !hadMetadata {
            onTrackStarted?(snapshot.artist, snapshot.title, snapshot.trackDuration)
        }

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
            } else if lastSnapshot.identityToken != nil && snapshot.identityToken == nil && !isReconnecting {
                // Stream restart (e.g. quality change) resets the token.
                // Reconnect restarts also reset it — those stay in-segment
                // unless the stall itself drags on.
                closeOpenSegment(at: now, reason: .channelSwitch)
            } else if reconnectingTicks > 10 {
                closeOpenSegment(at: now, reason: .stall)
            }
        }

        // Open condition — even before track metadata arrives, so buffering
        // and jingles count toward station time.
        if openSegmentId == nil, enabled, snapshot.isPlaying, !isReconnecting,
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
                trackId: snapshot.trackId,
                artPath: snapshot.artPath
            )
            openSegmentStartedAt = now
            openSegmentTrackId = snapshot.trackId
            log.info("segment open: \(channelName, privacy: .public) [\(network, privacy: .public)]")
        } else if let id = openSegmentId {
            // Enrichment: same segment, better metadata (first ICY/API arrival
            // or the API filling trackId after an ICY title flip). Never a
            // downgrade: an ICY-only snapshot (no trackId) must not overwrite
            // API-canonical metadata already attached to this segment.
            let isDowngrade = snapshot.trackId == nil && openSegmentTrackId != nil
            if !isDowngrade,
               snapshot.artist != lastSnapshot.artist
                || snapshot.title != lastSnapshot.title
                || snapshot.trackId != lastSnapshot.trackId
                || snapshot.artPath != lastSnapshot.artPath {
                store.enrich(
                    id: id, artist: snapshot.artist, title: snapshot.title,
                    trackId: snapshot.trackId, artPath: snapshot.artPath
                )
                openSegmentTrackId = snapshot.trackId
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
            if let startedAt = openSegmentStartedAt {
                allTimeClosedBase += date.timeIntervalSince(startedAt)
                // lastSnapshot still holds the closing segment's metadata —
                // the tick's defer hasn't run yet on the track-change path.
                onSegmentClosed?(
                    lastSnapshot.artist, lastSnapshot.title, lastSnapshot.trackDuration,
                    startedAt, date, reason
                )
            }
        }
        openSegmentStartedAt = nil
        openSegmentTrackId = nil
        refreshTodayTotal()
        #if DEBUG
        if !verifiedAllTimeBase, let store {
            verifiedAllTimeBase = true
            let queried = store.listenedSeconds(since: Date(timeIntervalSince1970: 0))
            assert(
                abs(queried - allTimeListenedSeconds) < 10,
                "all-time cache drifted: queried \(queried) vs cached \(allTimeListenedSeconds)"
            )
        }
        #endif
    }

    // MARK: - Scrobble queue pass-throughs (the store stays private)

    func enqueueScrobble(listenedAt: Date, artist: String, title: String, duration: Int?, network: String, channelName: String) {
        store?.enqueueScrobble(
            listenedAt: listenedAt, artist: artist, title: title,
            duration: duration, network: network, channelName: channelName
        )
    }

    func pendingScrobbles(service: HistoryStore.ScrobbleService, limit: Int = 50) -> [HistoryStore.PendingScrobble] {
        store?.pendingScrobbles(service: service, limit: limit) ?? []
    }

    func markScrobblesSent(ids: [Int64], service: HistoryStore.ScrobbleService) {
        store?.markScrobblesSent(ids: ids, service: service)
    }

    func bumpScrobbleAttempts(ids: [Int64]) {
        store?.bumpScrobbleAttempts(ids: ids)
    }

    func maintainScrobbleQueue() {
        store?.expireLastFMScrobbles(olderThan: Date(timeIntervalSinceNow: -14 * 86_400))
        store?.purgeSentScrobbles(olderThan: Date(timeIntervalSinceNow: -86_400))
    }

    func allListensForExport() -> [HistoryStore.ListenEntry] {
        store?.allListensForExport() ?? []
    }

    private func refreshTodayTotal() {
        guard let store else { return }
        todayListenedSeconds = store.listenedSeconds(since: Calendar.current.startOfDay(for: Date()))
        let openElapsed = openSegmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        allTimeListenedSeconds = allTimeClosedBase + openElapsed
    }

    private func sanitize(_ text: String?) -> String {
        guard let text, text != "Loading..." else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
