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
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
    }

    private func setupDebugNotifications() {
        #if DEBUG
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
