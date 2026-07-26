import XCTest
@testable import DIBar

final class ModelsTests: XCTestCase {
    // MARK: - NowPlaying.formatTime

    func testFormatTime() {
        XCTAssertEqual(NowPlaying.formatTime(0), "0:00")
        XCTAssertEqual(NowPlaying.formatTime(5), "0:05")
        XCTAssertEqual(NowPlaying.formatTime(65), "1:05")
        XCTAssertEqual(NowPlaying.formatTime(600), "10:00")
    }

    // MARK: - TrackArt

    func testStoragePathStripsCdnHost() {
        let url = URL(string: "https://cdn-images.audioaddict.com/8/f/a/cover.jpg")!
        XCTAssertEqual(TrackArt.storagePath(from: url), "/8/f/a/cover.jpg")
    }

    func testStoragePathKeepsForeignHostsInFull() {
        let url = URL(string: "https://example.com/art.jpg")!
        XCTAssertEqual(TrackArt.storagePath(from: url), "https://example.com/art.jpg")
    }

    func testUrlFromStoredPathRestoresCdnHost() {
        XCTAssertEqual(
            TrackArt.url(fromStored: "/8/f/a/cover.jpg")?.absoluteString,
            "https://cdn-images.audioaddict.com/8/f/a/cover.jpg"
        )
    }

    func testUrlFromStoredFullURLPassesThrough() {
        XCTAssertEqual(
            TrackArt.url(fromStored: "https://example.com/art.jpg")?.absoluteString,
            "https://example.com/art.jpg"
        )
    }

    func testUrlFromStoredEmptyIsNil() {
        XCTAssertNil(TrackArt.url(fromStored: nil))
        XCTAssertNil(TrackArt.url(fromStored: ""))
    }

    func testStorageRoundTrip() {
        let original = URL(string: "https://cdn-images.audioaddict.com/8/f/a/cover.jpg")!
        let stored = TrackArt.storagePath(from: original)
        XCTAssertEqual(TrackArt.url(fromStored: stored), original)
    }

    func testThumbnailURLAddsSizeQuery() {
        let url = URL(string: "https://cdn-images.audioaddict.com/8/f/a/cover.jpg")!
        XCTAssertEqual(
            TrackArt.thumbnailURL(url, pixelSize: 64)?.absoluteString,
            "https://cdn-images.audioaddict.com/8/f/a/cover.jpg?size=64x64"
        )
    }

    func testThumbnailURLReplacesExistingQuery() {
        let url = URL(string: "https://cdn-images.audioaddict.com/cover.jpg?size=300x300")!
        XCTAssertEqual(
            TrackArt.thumbnailURL(url, pixelSize: 64)?.absoluteString,
            "https://cdn-images.audioaddict.com/cover.jpg?size=64x64"
        )
    }

    // MARK: - AuthResponse email

    func testAuthResponseDecodesTopLevelEmail() throws {
        let json = Data("""
        {"listen_key": "abc", "email": "user@example.com"}
        """.utf8)
        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.resolvedEmail, "user@example.com")
    }

    func testAuthResponseFallsBackToMemberEmail() throws {
        let json = Data("""
        {"listen_key": "abc", "member": {"id": 1, "email": "member@example.com"}}
        """.utf8)
        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.resolvedEmail, "member@example.com")
    }

    func testAuthResponseEmailMissingIsNil() throws {
        let json = Data("""
        {"listen_key": "abc"}
        """.utf8)
        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertNil(response.resolvedEmail)
    }

    // MARK: - MembershipSubscription dates

    private func subscription(
        expiresOn: String? = nil,
        firstTrialAt: String? = nil,
        createdAt: String? = nil
    ) -> MembershipSubscription {
        MembershipSubscription(
            status: "active", autoRenew: true, trial: false,
            expiresOn: expiresOn, firstTrialAt: firstTrialAt,
            createdAt: createdAt, networkId: 1
        )
    }

    func testExpiresOnParsesDateOnly() {
        let date = subscription(expiresOn: "2026-01-31").expiresOnDate
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 1)
        XCTAssertEqual(parts.day, 31)
    }

    func testInternetDateParsesWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(subscription(firstTrialAt: "2025-06-01T12:34:56.789Z").firstTrialDate)
        XCTAssertNotNil(subscription(firstTrialAt: "2025-06-01T12:34:56Z").firstTrialDate)
        XCTAssertNil(subscription(firstTrialAt: "not a date").firstTrialDate)
    }

    func testStartedDatePrefersFirstTrial() {
        let both = subscription(
            firstTrialAt: "2025-06-01T00:00:00Z",
            createdAt: "2025-07-01T00:00:00Z"
        )
        XCTAssertEqual(both.startedDate, both.firstTrialDate)

        let createdOnly = subscription(createdAt: "2025-07-01T00:00:00Z")
        XCTAssertEqual(createdOnly.startedDate, createdOnly.createdAtDate)
    }
}
