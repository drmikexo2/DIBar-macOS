import AppKit
import os

#if DEBUG
private let log = Logger(subsystem: "com.dibar", category: "App")

/// Distributed-notification hooks for driving the app from scripts during
/// development (notifyutil / distributed notifications from the CLI).
extension AppDelegate {
    func setupDebugNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.playFirst"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let appState = self?.appState, let channel = appState.channels.first else {
                    log.error("DEBUG: no channels loaded")
                    return
                }
                log.error("DEBUG: playing '\(channel.name, privacy: .public)'")
                appState.playChannel(channel)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.selectNetwork"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.object as? String
            Task { @MainActor in
                guard let raw, let network = Network(rawValue: raw) else {
                    log.error("DEBUG: unknown network '\(raw ?? "nil", privacy: .public)'")
                    return
                }
                log.error("DEBUG: selecting network \(network.rawValue, privacy: .public)")
                self?.appState.selectNetwork(network)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.togglePlayPause"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.togglePlayPause()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.stop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.audioPlayer.stop()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.openHistory"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showHistoryWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.toggleArt"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("debugToggleArt"), object: nil)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.togglePanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.togglePanel(nil) }
        }

        log.error("DEBUG: notification handlers registered")
    }
}
#else
extension AppDelegate {
    func setupDebugNotifications() {}
}
#endif
