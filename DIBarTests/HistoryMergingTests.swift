import XCTest
@testable import DIBar

@MainActor
final class HistoryMergingTests: XCTestCase {
    /// Entries are newest-first, matching `HistoryStore.recentListens`.
    private func entry(
        id: Int64,
        start: TimeInterval,
        duration: TimeInterval,
        network: String = "di",
        channel: String = "Vocal Trance",
        artist: String = "Above & Beyond",
        title: String = "Sun & Moon",
        trackId: Int? = 100,
        vote: Int? = nil
    ) -> HistoryStore.ListenEntry {
        HistoryStore.ListenEntry(
            id: id,
            startedAt: Date(timeIntervalSince1970: start),
            duration: duration,
            network: network,
            channelName: channel,
            artist: artist,
            title: title,
            trackId: trackId,
            vote: vote,
            artURL: nil
        )
    }

    func testMergesPauseSplitWithinGap() {
        let older = entry(id: 1, start: 1000, duration: 60)
        let newer = entry(id: 2, start: 1120, duration: 30) // 60s gap after older ends
        let merged = HistoryRecorder.mergingAdjacent([newer, older])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, 2)
        XCTAssertEqual(merged[0].startedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(merged[0].duration, 90)
    }

    func testKeepsSeparateBeyondMaxGap() {
        let older = entry(id: 1, start: 1000, duration: 60)
        let newer = entry(id: 2, start: 1000 + 60 + 301, duration: 30)
        XCTAssertEqual(HistoryRecorder.mergingAdjacent([newer, older]).count, 2)
    }

    func testKeepsSeparateAcrossChannels() {
        let older = entry(id: 1, start: 1000, duration: 60)
        let newer = entry(id: 2, start: 1120, duration: 30, channel: "Progressive")
        XCTAssertEqual(HistoryRecorder.mergingAdjacent([newer, older]).count, 2)
    }

    func testKeepsSeparateForDifferentTrackIds() {
        let older = entry(id: 1, start: 1000, duration: 60, trackId: 100)
        let newer = entry(id: 2, start: 1120, duration: 30, trackId: 200)
        XCTAssertEqual(HistoryRecorder.mergingAdjacent([newer, older]).count, 2)
    }

    func testBridgesIcyRemixSuffixAndPrefersCanonicalMetadata() {
        // ICY-only segment (no trackId) carries a remix suffix; the API
        // segment knows its trackId and the canonical title.
        let older = entry(id: 1, start: 1000, duration: 60, title: "Sun & Moon (Club Mix)", trackId: nil)
        let newer = entry(id: 2, start: 1120, duration: 30, title: "Sun & Moon", trackId: 100)
        let merged = HistoryRecorder.mergingAdjacent([newer, older])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "Sun & Moon")
        XCTAssertEqual(merged[0].trackId, 100)
    }

    func testKeepsVoteFromEitherSide() {
        let older = entry(id: 1, start: 1000, duration: 60, vote: 1)
        let newer = entry(id: 2, start: 1120, duration: 30, vote: nil)
        let merged = HistoryRecorder.mergingAdjacent([newer, older])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].vote, 1)
    }

    func testChainOfThreeCollapsesToOne() {
        let a = entry(id: 1, start: 1000, duration: 60)
        let b = entry(id: 2, start: 1100, duration: 60)
        let c = entry(id: 3, start: 1200, duration: 60)
        let merged = HistoryRecorder.mergingAdjacent([c, b, a])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].duration, 180)
        XCTAssertEqual(merged[0].startedAt, Date(timeIntervalSince1970: 1000))
    }
}
