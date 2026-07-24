import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if appState.isLoggedIn {
                VStack(spacing: 0) {
                    if appState.audioPlayer.playbackError != nil, appState.playbackFailureLooksLikeNoPremium {
                        let network = appState.playingNetwork ?? appState.selectedNetwork
                        ErrorBanner(
                            message: "Playback failed — premium subscription may be required",
                            actionTitle: "Subscribe",
                            action: { openURL(network.subscriptionURL) },
                            onDismiss: { appState.audioPlayer.playbackError = nil }
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
