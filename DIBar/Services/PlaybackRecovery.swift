import AppKit
import Network
import os

private let log = Logger(subsystem: "com.dibar", category: "PlaybackRecovery")

/// Watches network-path and sleep/wake transitions and nudges AudioPlayer
/// back to life; all playback decisions stay in AudioPlayer itself.
@MainActor
final class PlaybackRecovery {
    private unowned let player: AudioPlayer
    private let pathMonitor = NWPathMonitor()
    private var pathWasSatisfied = true
    private var wasPlayingBeforeSleep = false

    init(player: AudioPlayer) {
        self.player = player

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = satisfied && !self.pathWasSatisfied
                self.pathWasSatisfied = satisfied
                if cameBack {
                    log.info("network path restored")
                    self.player.networkPathRestored()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.dibar.pathmonitor"))

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wasPlayingBeforeSleep = self.player.isPlaying
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wasPlayingBeforeSleep else { return }
                self.wasPlayingBeforeSleep = false
                log.info("wake: restarting stream")
                // Give the network stack a moment to re-attach before the
                // restart; a failure here falls into the normal backoff loop.
                try? await Task.sleep(for: .seconds(2))
                self.player.restartAfterWake()
            }
        }
    }
}
