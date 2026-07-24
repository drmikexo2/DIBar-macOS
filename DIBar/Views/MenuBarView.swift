import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if appState.isLoggedIn {
                VStack(spacing: 0) {
                    if let network = appState.subscriptionRequiredNetwork {
                        ErrorBanner(
                            message: "Premium subscription required for \(network.displayName)",
                            actionTitle: "Subscribe",
                            action: { openURL(network.subscriptionURL) },
                            onDismiss: { appState.subscriptionRequiredNetwork = nil }
                        )
                        Divider()
                    } else if let message = appState.errorMessage ?? appState.audioPlayer.playbackError {
                        ErrorBanner(message: message) {
                            appState.errorMessage = nil
                            appState.audioPlayer.playbackError = nil
                        }
                        Divider()
                    }
                    PlayerControlsView()
                    Divider()
                    StationListView()
                    Divider()
                    SettingsView()
                }
            } else {
                LoginView()
            }
        }
        .frame(width: 320)
    }
}
