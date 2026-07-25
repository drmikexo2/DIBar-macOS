import XCTest
@testable import DIBar

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore!
    private var dbURL: URL!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dibar-test-\(UUID().uuidString).sqlite3")
        store = try XCTUnwrap(HistoryStore(url: dbURL))
    }

    override func tearDown() async throws {
        store?.checkpointAndClose()
        store = nil
        if let dbURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: dbURL.path + suffix)
                )
            }
        }
    }

    @discardableResult
    private func openSegment(start: Date, trackId: Int? = 1) -> Int64 {
        store.openSegment(
            startedAt: start,
            network: "di",
            channelId: 7,
            channelKey: "vocaltrance",
            channelName: "Vocal Trance",
            artist: "Above & Beyond",
            title: "Sun & Moon",
            trackId: trackId,
            artPath: nil
        )!
    }

    func testOpenCloseRoundTrip() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = openSegment(start: start)
        store.close(id: id, at: start.addingTimeInterval(120), reason: .trackChange)

        let listens = store.recentListens(limit: 10)
        XCTAssertEqual(listens.count, 1)
        XCTAssertEqual(listens[0].id, id)
        XCTAssertEqual(listens[0].duration, 120, accuracy: 0.001)
        XCTAssertEqual(listens[0].artist, "Above & Beyond")
        XCTAssertEqual(listens[0].channelName, "Vocal Trance")
    }

    func testListenedSecondsCountsOpenSegmentToHeartbeat() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = openSegment(start: start)
        store.heartbeat(id: id, at: start.addingTimeInterval(45))

        XCTAssertEqual(store.listenedSeconds(since: .distantPast), 45, accuracy: 0.001)
        // The open segment must not leak into the closed base
        XCTAssertEqual(store.closedListenedSeconds(), 0, accuracy: 0.001)
    }

    func testClosedListenedSecondsMatchesClosedDurations() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = openSegment(start: start)
        store.close(id: first, at: start.addingTimeInterval(100), reason: .trackChange)
        let second = openSegment(start: start.addingTimeInterval(200))
        store.close(id: second, at: start.addingTimeInterval(250), reason: .stop)

        XCTAssertEqual(store.closedListenedSeconds(), 150, accuracy: 0.001)
        XCTAssertEqual(store.listenedSeconds(since: .distantPast), 150, accuracy: 0.001)
    }

    func testListenedSecondsSinceFiltersByStart() {
        let early = Date(timeIntervalSince1970: 1_000_000)
        let late = Date(timeIntervalSince1970: 2_000_000)
        let a = openSegment(start: early)
        store.close(id: a, at: early.addingTimeInterval(60), reason: .stop)
        let b = openSegment(start: late)
        store.close(id: b, at: late.addingTimeInterval(30), reason: .stop)

        XCTAssertEqual(
            store.listenedSeconds(since: Date(timeIntervalSince1970: 1_500_000)),
            30, accuracy: 0.001
        )
    }

    func testDeleteRemovesSegment() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = openSegment(start: start)
        store.close(id: id, at: start.addingTimeInterval(60), reason: .stop)
        store.delete(id: id)
        XCTAssertTrue(store.recentListens(limit: 10).isEmpty)
        XCTAssertEqual(store.closedListenedSeconds(), 0, accuracy: 0.001)
    }

    func testRecentListensNewestFirst() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let a = openSegment(start: start)
        store.close(id: a, at: start.addingTimeInterval(60), reason: .stop)
        let b = openSegment(start: start.addingTimeInterval(500))
        store.close(id: b, at: start.addingTimeInterval(560), reason: .stop)

        let listens = store.recentListens(limit: 10)
        XCTAssertEqual(listens.map(\.id), [b, a])
    }
}
