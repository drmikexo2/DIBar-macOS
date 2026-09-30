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

    func testHoveringANonCurrentRowShowsThePlayAffordance() {
        XCTAssertEqual(SpeakerIndicatorPresentation.playLeadingOffset, 2)
        XCTAssertEqual(
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: false,
                isAudible: false,
                waveFrame: 0,
                isHovered: true
            ),
            "play.fill"
        )
    }

    func testHoverDoesNotDisplaceTheCurrentStationIndicator() {
        XCTAssertEqual(
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: true,
                isAudible: false,
                waveFrame: 0,
                isHovered: true
            ),
            "speaker.fill"
        )
        XCTAssertEqual(
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: true,
                isAudible: true,
                waveFrame: 1,
                isHovered: true
            ),
            "speaker.wave.2.fill"
        )
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

    func testStartingStationLooksActiveBeforeAudioIsAudible() {
        XCTAssertEqual(
            SpeakerIndicatorPresentation.symbolName(
                isCurrent: true,
                isAudible: false,
                waveFrame: 0,
                isHovered: true,
                isStarting: true
            ),
            SpeakerIndicatorPresentation.steadyWaveSymbol
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
            SpeakerIndicatorPresentation.waveSymbols.last,
            SpeakerIndicatorPresentation.maximumWaveSymbol
        )
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

    func testCompactLeadingIndicatorSlotClearsText() {
        XCTAssertEqual(SpeakerIndicatorPresentation.glyphSize, 10)
        XCTAssertEqual(PanelMetrics.iconSlot, 18)
        XCTAssertEqual(PanelMetrics.leadingControlColumn, 26)
        XCTAssertEqual(PanelMetrics.textColumn, 26)
        XCTAssertEqual(
            (PanelMetrics.leadingControlColumn - PanelMetrics.iconSlot) / 2,
            4
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

    func testResumesWhenAStagedUpdateIsNotTheRunningVersion() {
        XCTAssertTrue(PendingUpdatePolicy.shouldResume(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "9",
            runningVersion: "1.4.1",
            attempts: 0
        ))
    }

    func testDoesNotResumeWhenNothingIsStaged() {
        XCTAssertFalse(PendingUpdatePolicy.shouldResume(
            pendingBuild: nil,
            pendingVersion: nil,
            runningBuild: "9",
            runningVersion: "1.4.1",
            attempts: 0
        ))
        XCTAssertFalse(PendingUpdatePolicy.shouldResume(
            pendingBuild: nil,
            pendingVersion: "",
            runningBuild: "9",
            runningVersion: "1.4.1",
            attempts: 0
        ))
    }

    func testDoesNotResumeOnceTheStagedVersionIsRunning() {
        XCTAssertFalse(PendingUpdatePolicy.shouldResume(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "10",
            runningVersion: "1.4.2",
            attempts: 0
        ))
        XCTAssertTrue(PendingUpdatePolicy.didInstall(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "10",
            runningVersion: "1.4.2"
        ))
        XCTAssertFalse(PendingUpdatePolicy.didInstall(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "9",
            runningVersion: "1.4.2"
        ))
        XCTAssertTrue(PendingUpdatePolicy.didInstall(
            pendingBuild: nil,
            pendingVersion: "1.4.2",
            runningBuild: "10",
            runningVersion: "1.4.2"
        ))
        XCTAssertFalse(PendingUpdatePolicy.didInstall(
            pendingBuild: nil,
            pendingVersion: nil,
            runningBuild: "10",
            runningVersion: "1.4.2"
        ))
    }

    func testGivesUpAfterRepeatedFailedAttempts() {
        let last = PendingUpdatePolicy.maxAttempts - 1
        XCTAssertTrue(PendingUpdatePolicy.shouldResume(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "9",
            runningVersion: "1.4.1",
            attempts: last
        ))
        XCTAssertFalse(PendingUpdatePolicy.shouldResume(
            pendingBuild: "10",
            pendingVersion: "1.4.2",
            runningBuild: "9",
            runningVersion: "1.4.1",
            attempts: PendingUpdatePolicy.maxAttempts
        ))
    }

    func testUpToDateIsNotReportedAsAFailure() {
        // SUNoUpdateError; Sparkle routes the ordinary up-to-date result
        // through the same abort callback as real failures.
        XCTAssertFalse(PendingUpdatePolicy.isReportableFailure(errorCode: 1001))
        XCTAssertTrue(PendingUpdatePolicy.isReportableFailure(errorCode: 4001))
    }

    func testPresentationStateShowsAndClearsAvailableVersion() async {
        await MainActor.run {
            let state = UpdatePresentationState()
            XCTAssertNil(state.phase)
            state.showAvailable(version: "1.4")
            XCTAssertEqual(state.phase, .available(version: "1.4"))
            state.showReady(version: "1.4")
            state.clearAvailable()
            XCTAssertEqual(state.phase, .ready(version: "1.4"))
            state.clear()
            XCTAssertNil(state.phase)
        }
    }

    func testAutomaticInstallRequiresNoPlaybackOrVisibleUI() {
        XCTAssertTrue(UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: false,
            isPanelVisible: false,
            isSettingsVisible: false,
            isHistoryVisible: false
        ))
        XCTAssertFalse(UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: true,
            isPanelVisible: false,
            isSettingsVisible: false,
            isHistoryVisible: false
        ))
        XCTAssertFalse(UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: false,
            isPanelVisible: true,
            isSettingsVisible: false,
            isHistoryVisible: false
        ))
        XCTAssertFalse(UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: false,
            isPanelVisible: false,
            isSettingsVisible: true,
            isHistoryVisible: false
        ))
        XCTAssertFalse(UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: false,
            isPanelVisible: false,
            isSettingsVisible: false,
            isHistoryVisible: true
        ))
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

final class AutomaticPlaybackRestorePolicyTests: XCTestCase {
    func testPendingUpdateDefersAndReleasesAutoplayOnce() {
        var policy = AutomaticPlaybackRestorePolicy(isSuppressed: true)

        XCTAssertFalse(policy.requestRestore(isEnabled: true))
        XCTAssertTrue(policy.restoreWasDeferred)
        XCTAssertTrue(policy.release(isEnabled: true))
        XCTAssertFalse(policy.release(isEnabled: true))
        XCTAssertTrue(policy.requestRestore(isEnabled: true))
    }

    func testExplicitPlaybackSupersedesDeferredAutoplay() {
        var policy = AutomaticPlaybackRestorePolicy(isSuppressed: true)

        XCTAssertFalse(policy.requestRestore(isEnabled: true))
        policy.noteExplicitPlayback()
        XCTAssertFalse(policy.release(isEnabled: true))
    }

    func testLateSuppressionStillGatesUpcomingAutoplay() {
        var policy = AutomaticPlaybackRestorePolicy()

        policy.suppress()
        XCTAssertFalse(policy.requestRestore(isEnabled: true))
        XCTAssertTrue(policy.release(isEnabled: true))
    }

    func testDisabledAutoplayNeverDefersOrResumes() {
        var policy = AutomaticPlaybackRestorePolicy(isSuppressed: true)

        XCTAssertFalse(policy.requestRestore(isEnabled: false))
        XCTAssertFalse(policy.restoreWasDeferred)
        XCTAssertFalse(policy.release(isEnabled: false))
        XCTAssertFalse(policy.requestRestore(isEnabled: false))
    }

    func testTurningAutoplayOffDiscardsDeferredRestore() {
        var policy = AutomaticPlaybackRestorePolicy(isSuppressed: true)

        XCTAssertFalse(policy.requestRestore(isEnabled: true))
        XCTAssertFalse(policy.release(isEnabled: false))
        XCTAssertFalse(policy.restoreWasDeferred)
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
