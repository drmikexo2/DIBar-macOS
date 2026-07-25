import XCTest
@testable import DIBar

final class TrackMatchingTests: XCTestCase {
    // MARK: - mergeKey

    func testMergeKeyLowercasesAndCollapsesWhitespace() {
        XCTAssertEqual(TrackMatching.mergeKey("  Get  It   On "), "get it on")
    }

    func testMergeKeyFoldsQuoteVariants() {
        XCTAssertEqual(TrackMatching.mergeKey("Don\u{2019}t Stop"), "don't stop")
        XCTAssertEqual(TrackMatching.mergeKey("Don`t Stop"), "don't stop")
        XCTAssertEqual(TrackMatching.mergeKey("Don´t Stop"), "don't stop")
        XCTAssertEqual(TrackMatching.mergeKey("Don\u{02BC}t Stop"), "don't stop")
    }

    func testMergeKeyMakesQuoteVariantsCompareEqual() {
        XCTAssertEqual(
            TrackMatching.mergeKey("Don\u{2019}t Stop Believin\u{2019}"),
            TrackMatching.mergeKey("Don't Stop Believin'")
        )
    }

    // MARK: - sameSong

    func testSameSongExactMatch() {
        XCTAssertTrue(TrackMatching.sameSong(
            artistA: "T. Rex", titleA: "Get It On",
            artistB: "t. rex", titleB: "get it on"
        ))
    }

    func testSameSongBridgesRemixSuffixInParens() {
        XCTAssertTrue(TrackMatching.sameSong(
            artistA: "T. Rex", titleA: "Get It On",
            artistB: "T. Rex", titleB: "Get It On (Saison Remix)"
        ))
        // Symmetric: either side may carry the suffix
        XCTAssertTrue(TrackMatching.sameSong(
            artistA: "T. Rex", titleA: "Get It On (Saison Remix)",
            artistB: "T. Rex", titleB: "Get It On"
        ))
    }

    func testSameSongBridgesExtensionAtSpaceBoundary() {
        XCTAssertTrue(TrackMatching.sameSong(
            artistA: "A", titleA: "Get It On",
            artistB: "A", titleB: "Get It On Tonight"
        ))
    }

    func testSameSongRejectsMidWordExtension() {
        XCTAssertFalse(TrackMatching.sameSong(
            artistA: "A", titleA: "Get It On",
            artistB: "A", titleB: "Get It Online"
        ))
    }

    func testSameSongRejectsDifferentArtists() {
        XCTAssertFalse(TrackMatching.sameSong(
            artistA: "T. Rex", titleA: "Get It On",
            artistB: "Power Station", titleB: "Get It On"
        ))
    }

    func testSameSongEmptyArtistsFallBackToTitles() {
        XCTAssertTrue(TrackMatching.sameSong(
            artistA: "", titleA: "Get It On",
            artistB: "", titleB: "Get It On (Saison Remix)"
        ))
    }

    func testSameSongRejectsEmptyTitles() {
        XCTAssertFalse(TrackMatching.sameSong(
            artistA: "A", titleA: "",
            artistB: "A", titleB: ""
        ))
    }
}
