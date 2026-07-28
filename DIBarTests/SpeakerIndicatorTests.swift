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
}
