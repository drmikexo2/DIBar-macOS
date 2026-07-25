import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.dibar", category: "HistoryStore")

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed storage for listening history. One row per continuous
/// stretch of one track on one channel; pauses close rows, so paused time
/// never counts as listening. Errors disable the store rather than crash.
@MainActor
final class HistoryStore {
    enum EndReason: String {
        case trackChange = "track_change"
        case pause
        case stop
        case channelSwitch = "switch"
        case quit
        case sleep
        case crash
        case stall
    }

    private var db: OpaquePointer?

    static func defaultURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("DIBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite3")
    }

    init?(url: URL) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            log.error("open failed: \(url.path, privacy: .public)")
            sqlite3_close(db)
            return nil
        }
        // Art columns arrived after 1.0 (v4 on listen_segments, v5 on
        // song_votes); older DBs need them grafted on before the new SQL
        // runs. Version 0 means a fresh DB — the CREATEs below cover it.
        let previousVersion = userVersion()
        if previousVersion > 0 {
            if previousVersion < 4 {
                guard exec("ALTER TABLE listen_segments ADD COLUMN art_url TEXT;") else {
                    sqlite3_close(db)
                    return nil
                }
            }
            if previousVersion < 5 {
                guard exec("ALTER TABLE song_votes ADD COLUMN art_url TEXT;") else {
                    sqlite3_close(db)
                    return nil
                }
            }
        }
        let setup = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA user_version = 5;
        CREATE TABLE IF NOT EXISTS listen_segments (
            id INTEGER PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            last_seen_at REAL NOT NULL,
            network TEXT NOT NULL,
            channel_id INTEGER NOT NULL,
            channel_key TEXT NOT NULL,
            channel_name TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            track_id INTEGER,
            end_reason TEXT,
            art_url TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_segments_started ON listen_segments(started_at);
        CREATE INDEX IF NOT EXISTS idx_segments_net_started ON listen_segments(network, started_at);
        CREATE INDEX IF NOT EXISTS idx_segments_artist_title ON listen_segments(artist, title);
        CREATE TABLE IF NOT EXISTS song_votes (
            track_id INTEGER PRIMARY KEY,
            vote INTEGER NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            network TEXT NOT NULL,
            channel_id INTEGER NOT NULL,
            channel_name TEXT NOT NULL,
            voted_at REAL NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0,
            art_url TEXT
        );
        CREATE TABLE IF NOT EXISTS pending_scrobbles (
            id INTEGER PRIMARY KEY,
            listened_at REAL NOT NULL,
            artist TEXT NOT NULL,
            title TEXT NOT NULL,
            duration INTEGER,
            network TEXT NOT NULL,
            channel_name TEXT NOT NULL,
            sent_lastfm INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0
        );
        """
        guard exec(setup) else {
            sqlite3_close(db)
            return nil
        }
        log.info("history store open at \(url.path, privacy: .public)")
    }

    /// Close any segments left open by a crash or kill. Idempotent.
    @discardableResult
    func recoverDanglingSegments() -> Int {
        guard exec("UPDATE listen_segments SET ended_at = last_seen_at, end_reason = 'crash' WHERE ended_at IS NULL;")
        else { return 0 }
        let recovered = Int(sqlite3_changes(db))
        if recovered > 0 {
            log.info("recovered \(recovered) dangling segment(s)")
        }
        return recovered
    }

    func openSegment(
        startedAt: Date,
        network: String,
        channelId: Int,
        channelKey: String,
        channelName: String,
        artist: String,
        title: String,
        trackId: Int?,
        artPath: String?
    ) -> Int64? {
        let sql = """
        INSERT INTO listen_segments
            (started_at, last_seen_at, network, channel_id, channel_key, channel_name, artist, title, track_id, art_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }
        let t = startedAt.timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, t)
        sqlite3_bind_double(stmt, 2, t)
        sqlite3_bind_text(stmt, 3, network, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 4, Int64(channelId))
        sqlite3_bind_text(stmt, 5, channelKey, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 6, channelName, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 7, artist, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 8, title, -1, sqliteTransient)
        if let trackId {
            sqlite3_bind_int64(stmt, 9, Int64(trackId))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let artPath {
            sqlite3_bind_text(stmt, 10, artPath, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        guard step(stmt) else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func heartbeat(id: Int64, at date: Date) {
        var stmt: OpaquePointer?
        guard prepare("UPDATE listen_segments SET last_seen_at = ? WHERE id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        _ = step(stmt)
    }

    func enrich(id: Int64, artist: String, title: String, trackId: Int?, artPath: String?) {
        var stmt: OpaquePointer?
        // COALESCE: an ICY-only update carries no art and must not wipe
        // art the API already provided for this segment.
        guard prepare("UPDATE listen_segments SET artist = ?, title = ?, track_id = ?, art_url = COALESCE(?, art_url) WHERE id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, artist, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, title, -1, sqliteTransient)
        if let trackId {
            sqlite3_bind_int64(stmt, 3, Int64(trackId))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let artPath {
            sqlite3_bind_text(stmt, 4, artPath, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, id)
        _ = step(stmt)
    }

    func close(id: Int64, at date: Date, reason: EndReason) {
        var stmt: OpaquePointer?
        guard prepare("UPDATE listen_segments SET ended_at = ?, last_seen_at = ?, end_reason = ? WHERE id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        let t = date.timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, t)
        sqlite3_bind_double(stmt, 2, t)
        sqlite3_bind_text(stmt, 3, reason.rawValue, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 4, id)
        _ = step(stmt)
    }

    func delete(id: Int64) {
        var stmt: OpaquePointer?
        guard prepare("DELETE FROM listen_segments WHERE id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        _ = step(stmt)
    }

    /// Total listening time across all closed segments — the stable base for
    /// the recorder's cached all-time total (the open segment is added
    /// arithmetically, so this full-table scan runs once per launch).
    func closedListenedSeconds() -> TimeInterval {
        var stmt: OpaquePointer?
        guard prepare(
            "SELECT COALESCE(SUM(ended_at - started_at), 0) FROM listen_segments WHERE ended_at IS NOT NULL;",
            &stmt
        ) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    /// Total listening time for segments started on or after `since`,
    /// counting the open segment up to its last heartbeat.
    func listenedSeconds(since: Date) -> TimeInterval {
        var stmt: OpaquePointer?
        guard prepare(
            "SELECT COALESCE(SUM(COALESCE(ended_at, last_seen_at) - started_at), 0) FROM listen_segments WHERE started_at >= ?;",
            &stmt
        ) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    // MARK: - Song votes

    func setVote(
        trackId: Int,
        vote: Int,
        artist: String,
        title: String,
        network: String,
        channelId: Int,
        channelName: String,
        at date: Date,
        synced: Bool,
        artPath: String?
    ) {
        let sql = """
        INSERT INTO song_votes (track_id, vote, artist, title, network, channel_id, channel_name, voted_at, synced, art_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(track_id) DO UPDATE SET
            vote = excluded.vote, artist = excluded.artist, title = excluded.title,
            network = excluded.network, channel_id = excluded.channel_id,
            channel_name = excluded.channel_name, voted_at = excluded.voted_at,
            synced = excluded.synced,
            art_url = COALESCE(excluded.art_url, art_url);
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(trackId))
        sqlite3_bind_int64(stmt, 2, Int64(vote))
        sqlite3_bind_text(stmt, 3, artist, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, title, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 5, network, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 6, Int64(channelId))
        sqlite3_bind_text(stmt, 7, channelName, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 8, date.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 9, synced ? 1 : 0)
        if let artPath {
            sqlite3_bind_text(stmt, 10, artPath, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        _ = step(stmt)
    }

    func clearVote(trackId: Int) {
        var stmt: OpaquePointer?
        guard prepare("DELETE FROM song_votes WHERE track_id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(trackId))
        _ = step(stmt)
    }

    func vote(forTrackId trackId: Int) -> Int? {
        var stmt: OpaquePointer?
        guard prepare("SELECT vote FROM song_votes WHERE track_id = ?;", &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(trackId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func markVoteSynced(trackId: Int) {
        var stmt: OpaquePointer?
        guard prepare("UPDATE song_votes SET synced = 1 WHERE track_id = ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(trackId))
        _ = step(stmt)
    }

    // MARK: - Read queries (history window)

    struct ListenEntry: Identifiable {
        let id: Int64
        let startedAt: Date
        let duration: TimeInterval
        let network: String
        let channelName: String
        let artist: String
        let title: String
        let trackId: Int?
        let vote: Int?
        let artURL: URL?
    }

    func recentListens(limit: Int) -> [ListenEntry] {
        let sql = """
        SELECT s.id, s.started_at, COALESCE(s.ended_at, s.last_seen_at) - s.started_at,
               s.network, s.channel_name, s.artist, s.title, s.track_id, v.vote, s.art_url
        FROM listen_segments s
        LEFT JOIN song_votes v ON v.track_id = s.track_id
        WHERE (s.artist != '' OR s.title != '')
        ORDER BY s.started_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var entries: [ListenEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(ListenEntry(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                duration: sqlite3_column_double(stmt, 2),
                network: String(cString: sqlite3_column_text(stmt, 3)),
                channelName: String(cString: sqlite3_column_text(stmt, 4)),
                artist: String(cString: sqlite3_column_text(stmt, 5)),
                title: String(cString: sqlite3_column_text(stmt, 6)),
                trackId: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7)),
                vote: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 8)),
                artURL: sqlite3_column_type(stmt, 9) == SQLITE_NULL
                    ? nil : TrackArt.url(fromStored: String(cString: sqlite3_column_text(stmt, 9)))
            ))
        }
        return entries
    }

    struct VoteEntry: Identifiable {
        let id: Int64
        let votedAt: Date
        let vote: Int
        let network: String
        let channelName: String
        let artist: String
        let title: String
        let artURL: URL?
    }

    func voteEntries(vote: Int, limit: Int) -> [VoteEntry] {
        // Votes cast before v5 have no stored art; fall back to art from any
        // listen of the same track.
        let sql = """
        SELECT v.track_id, v.voted_at, v.vote, v.network, v.channel_name, v.artist, v.title,
               COALESCE(v.art_url, (SELECT s.art_url FROM listen_segments s
                                    WHERE s.track_id = v.track_id AND s.art_url IS NOT NULL
                                    ORDER BY s.started_at DESC LIMIT 1))
        FROM song_votes v
        WHERE v.vote = ?
        ORDER BY v.voted_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(vote))
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var entries: [VoteEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(VoteEntry(
                id: sqlite3_column_int64(stmt, 0),
                votedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                vote: Int(sqlite3_column_int64(stmt, 2)),
                network: String(cString: sqlite3_column_text(stmt, 3)),
                channelName: String(cString: sqlite3_column_text(stmt, 4)),
                artist: String(cString: sqlite3_column_text(stmt, 5)),
                title: String(cString: sqlite3_column_text(stmt, 6)),
                artURL: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : TrackArt.url(fromStored: String(cString: sqlite3_column_text(stmt, 7)))
            ))
        }
        return entries
    }

    // MARK: - Scrobble queue

    enum ScrobbleService: String {
        case lastfm

        var sentColumn: String {
            switch self {
            case .lastfm: return "sent_lastfm"
            }
        }
    }

    struct PendingScrobble: Identifiable {
        let id: Int64
        let listenedAt: Date
        let artist: String
        let title: String
        let duration: Int?
        let network: String
        let channelName: String
    }

    func enqueueScrobble(
        listenedAt: Date,
        artist: String,
        title: String,
        duration: Int?,
        network: String,
        channelName: String
    ) {
        let sql = """
        INSERT INTO pending_scrobbles (listened_at, artist, title, duration, network, channel_name)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, listenedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, artist, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, title, -1, sqliteTransient)
        if let duration {
            sqlite3_bind_int64(stmt, 4, Int64(duration))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, network, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 6, channelName, -1, sqliteTransient)
        _ = step(stmt)
    }

    func pendingScrobbles(service: ScrobbleService, limit: Int) -> [PendingScrobble] {
        let sql = """
        SELECT id, listened_at, artist, title, duration, network, channel_name
        FROM pending_scrobbles
        WHERE \(service.sentColumn) = 0
        ORDER BY listened_at ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var entries: [PendingScrobble] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(PendingScrobble(
                id: sqlite3_column_int64(stmt, 0),
                listenedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                artist: String(cString: sqlite3_column_text(stmt, 2)),
                title: String(cString: sqlite3_column_text(stmt, 3)),
                duration: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4)),
                network: String(cString: sqlite3_column_text(stmt, 5)),
                channelName: String(cString: sqlite3_column_text(stmt, 6))
            ))
        }
        return entries
    }

    func markScrobblesSent(ids: [Int64], service: ScrobbleService) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard prepare("UPDATE pending_scrobbles SET \(service.sentColumn) = 1 WHERE id IN (\(placeholders));", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        _ = step(stmt)
    }

    func bumpScrobbleAttempts(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard prepare("UPDATE pending_scrobbles SET attempts = attempts + 1 WHERE id IN (\(placeholders));", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        _ = step(stmt)
    }

    /// Last.fm rejects scrobbles older than two weeks — mark them sent so the
    /// queue can drain.
    func expireLastFMScrobbles(olderThan cutoff: Date) {
        var stmt: OpaquePointer?
        guard prepare("UPDATE pending_scrobbles SET sent_lastfm = 1 WHERE sent_lastfm = 0 AND listened_at < ?;", &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        _ = step(stmt)
    }

    func purgeSentScrobbles(olderThan cutoff: Date) {
        var stmt: OpaquePointer?
        guard prepare(
            "DELETE FROM pending_scrobbles WHERE sent_lastfm = 1 AND listened_at < ?;",
            &stmt
        ) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        _ = step(stmt)
    }

    /// All listens with metadata, oldest first — for the stats.fm export.
    func allListensForExport() -> [ListenEntry] {
        let sql = """
        SELECT s.id, s.started_at, COALESCE(s.ended_at, s.last_seen_at) - s.started_at,
               s.network, s.channel_name, s.artist, s.title, s.track_id
        FROM listen_segments s
        WHERE (s.artist != '' OR s.title != '')
        ORDER BY s.started_at ASC;
        """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var entries: [ListenEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(ListenEntry(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                duration: sqlite3_column_double(stmt, 2),
                network: String(cString: sqlite3_column_text(stmt, 3)),
                channelName: String(cString: sqlite3_column_text(stmt, 4)),
                artist: String(cString: sqlite3_column_text(stmt, 5)),
                title: String(cString: sqlite3_column_text(stmt, 6)),
                trackId: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7)),
                vote: nil,
                artURL: nil
            ))
        }
        return entries
    }

    func checkpointAndClose() {
        _ = exec("PRAGMA wal_checkpoint(TRUNCATE);")
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Helpers

    private func userVersion() -> Int {
        var stmt: OpaquePointer?
        guard prepare("PRAGMA user_version;", &stmt) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func exec(_ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            log.error("exec error: \(message, privacy: .public)")
            return false
        }
        return true
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare error: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        return true
    }

    private func step(_ stmt: OpaquePointer?) -> Bool {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            log.error("step error: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        return true
    }
}
