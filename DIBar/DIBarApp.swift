import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "App")

@main
struct DIBarApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .onAppear {
                    setupDebugNotifications()
                }
        } label: {
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                if appState.showTrackInMenuBar, let title = appState.menuBarTrackText {
                    Text(title)
                } else if appState.audioPlayer.isPlaying {
                    Image(systemName: "play.fill")
                        .imageScale(.small)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private static var debugHandlersRegistered = false

    private func setupDebugNotifications() {
        #if DEBUG
        guard !Self.debugHandlersRegistered else { return }
        Self.debugHandlersRegistered = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.playFirst"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let channel = appState.channels.first else {
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
        ) { note in
            let raw = note.object as? String
            Task { @MainActor in
                guard let raw, let network = Network(rawValue: raw) else {
                    log.error("DEBUG: unknown network '\(raw ?? "nil", privacy: .public)'")
                    return
                }
                log.error("DEBUG: selecting network \(network.rawValue, privacy: .public)")
                appState.selectNetwork(network)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.toggleArt"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("debugToggleArt"), object: nil)
        }

        log.error("DEBUG: notification handlers registered")
        #endif
    }
}
