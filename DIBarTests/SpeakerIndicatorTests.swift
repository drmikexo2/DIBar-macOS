import XCTest
@testable import DIBar

final class SpeakerIndicatorTests: XCTestCase {
    func testWaveCadenceIsHalfACyclePerSecond() {
        XCTAssertEqual(SpeakerIndicatorPresentation.waveCycleDuration, 2.0)
        XCTAssertEqual(
            SpeakerIndicatorPresentation.waveFrameInterval,
            2.0 / 3.0,
            accuracy: 0.000_001
        )
    }

    func testInactiveIndicatorHasNoSymbol() {
        XCTAssertNil(SpeakerIndicatorPresentation.symbolName(
            isCurrent: false,
            isAudible: true,
            waveFrame: 0
        ))
    }

    func testCurrentNonAudibleIndicatorIsStaticSpeaker() {
        XCTAssertEqual(
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: true,
                isAudible: false,
                waveFrame: 3
            ),
            "speaker.fill"
        )
    }

    func testAudibleIndicatorCyclesOutwardThenLoops() {
        let symbols = (0..<6).map {
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: true,
                isAudible: true,
                waveFrame: $0
            )
        }
        XCTAssertEqual(symbols, [
            "speaker.wave.1.fill",
            "speaker.wave.2.fill",
            "speaker.wave.3.fill",
            "speaker.wave.1.fill",
            "speaker.wave.2.fill",
            "speaker.wave.3.fill",
        ])
    }

    func testReduceMotionUsesSteadyWave() {
        for frame in 0..<SpeakerIndicatorPresentation.waveFrameCount {
            XCTAssertEqual(
                SpeakerIndicatorPresentation.symbolName(
                    isCurrent: true,
                    isAudible: true,
                    waveFrame: frame,
                    reduceMotion: true
                ),
                "speaker.wave.2.fill"
            )
        }
    }

    func testWaveLayersKeepStableIdentities() {
        XCTAssertEqual(SpeakerIndicatorPresentation.waveSymbols, [
            "speaker.wave.1.fill",
            "speaker.wave.2.fill",
            "speaker.wave.3.fill",
        ])
        XCTAssertEqual(
            (0..<6).map {
                SpeakerIndicatorPresentation.waveIndex(
                    waveFrame: $0,
                    reduceMotion: false
                )
            },
            [0, 1, 2, 0, 1, 2]
        )
    }

    func testSpeakerClockOnlyRunsForVisibleAudibleMotion() {
        XCTAssertTrue(SpeakerAnimationPolicy.shouldRun(
            isPanelVisible: true,
            isAudiblyPlaying: true,
            reduceMotion: false
        ))
        XCTAssertFalse(SpeakerAnimationPolicy.shouldRun(
            isPanelVisible: false,
            isAudiblyPlaying: true,
            reduceMotion: false
        ))
        XCTAssertFalse(SpeakerAnimationPolicy.shouldRun(
            isPanelVisible: true,
            isAudiblyPlaying: false,
            reduceMotion: false
        ))
        XCTAssertFalse(SpeakerAnimationPolicy.shouldRun(
            isPanelVisible: true,
            isAudiblyPlaying: true,
            reduceMotion: true
        ))
    }
}

final class UpdateReminderTests: XCTestCase {
    func testScheduledUpdateOnlyLetsSparkleStealFocusAtOpportuneTime() {
        XCTAssertTrue(UpdateReminderPolicy.shouldLetSparklePresent(immediateFocus: true))
        XCTAssertFalse(UpdateReminderPolicy.shouldLetSparklePresent(immediateFocus: false))
    }

    func testBadgeOnlyAppearsForDeferredScheduledUpdate() {
        XCTAssertTrue(UpdateReminderPolicy.shouldShowBadge(
            handleShowingUpdate: false,
            userInitiated: false
        ))
        XCTAssertFalse(UpdateReminderPolicy.shouldShowBadge(
            handleShowingUpdate: true,
            userInitiated: false
        ))
        XCTAssertFalse(UpdateReminderPolicy.shouldShowBadge(
            handleShowingUpdate: false,
            userInitiated: true
        ))
    }

    func testPresentationStateShowsAndClearsAvailableVersion() async {
        await MainActor.run {
            let state = UpdatePresentationState()
            XCTAssertNil(state.availableVersion)
            state.show(version: "1.4")
            XCTAssertEqual(state.availableVersion, "1.4")
            state.clear()
            XCTAssertNil(state.availableVersion)
        }
    }

    func testUpdateBadgePreservesMenuBarLabelDimensions() async {
        await MainActor.run {
            let regular = MenuBarLabelRenderer.labelImage(
                line1: "Artist",
                line2: "Song",
                glyph: .playing
            )
            let badged = MenuBarLabelRenderer.labelImage(
                line1: "Artist",
                line2: "Song",
                glyph: .playing,
                showsUpdateBadge: true
            )

            XCTAssertEqual(regular.size, badged.size)
            XCTAssertNotEqual(regular.tiffRepresentation, badged.tiffRepresentation)
        }
    }
}

final class ArtCacheTests: XCTestCase {
    func testCacheUsesBoundedDecodedMemoryBudget() async {
        await MainActor.run {
            XCTAssertEqual(ArtCache.countLimit, 48)
            XCTAssertEqual(ArtCache.totalCostLimit, 16 * 1024 * 1024)
            XCTAssertEqual(
                ArtCache.imageCost(
                    pixelWidth: 300,
                    pixelHeight: 300,
                    downloadedByteCount: 24_000
                ),
                360_000
            )
        }
    }

    func testImageCostFallsBackToDownloadedBytes() async {
        await MainActor.run {
            XCTAssertEqual(
                ArtCache.imageCost(
                    pixelWidth: 0,
                    pixelHeight: 300,
                    downloadedByteCount: 24_000
                ),
                24_000
            )
            XCTAssertEqual(
                ArtCache.imageCost(
                    pixelWidth: Int.max,
                    pixelHeight: Int.max,
                    downloadedByteCount: 24_000
                ),
                24_000
            )
        }
    }

    func testArtworkSessionDoesNotDuplicateURLCache() async {
        await MainActor.run {
            let configuration = ArtCache.makeSessionConfiguration()
            XCTAssertNil(configuration.urlCache)
            XCTAssertEqual(
                configuration.requestCachePolicy,
                .reloadIgnoringLocalCacheData
            )
        }
    }
}
