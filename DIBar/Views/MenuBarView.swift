import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                VStack(spacing: 0) {
                    if let message = appState.errorMessage ?? appState.audioPlayer.playbackError {
                        ErrorBanner(message: message) {
                            appState.errorMessage = nil
                            appState.audioPlayer.playbackError = nil
                        }
                        Divider()
                    }
                    PlayerControlsView()
                    Divider()
                    NetworkTabBar()
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
