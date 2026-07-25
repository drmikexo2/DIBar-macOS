import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.dibar", category: "SleepTimer")

/// Session-only sleep timer; never persisted across launches. Fires `onFire`
/// once when the deadline passes, then goes quiet.
@Observable
@MainActor
final class SleepTimer {
    private(set) var endDate: Date?
    private var timer: Timer?

    /// What to do when the timer fires (pause playback, maybe quit).
    var onFire: (() -> Void)?

    func start(minutes: Int) {
        let clamped = min(max(minutes, 1), 720)
        endDate = Date().addingTimeInterval(TimeInterval(clamped * 60))
        // A 1s date-compare timer instead of a one-shot: after system sleep the
        // next tick still fires an overdue timer correctly.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 0.3
        }
        log.info("sleep timer: set for \(clamped)min")
    }

    func cancel() {
        endDate = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let end = endDate, Date() >= end else { return }
        cancel()
        log.info("sleep timer: fired")
        onFire?()
    }
}
