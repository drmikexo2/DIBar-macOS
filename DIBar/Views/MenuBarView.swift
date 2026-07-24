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
                    footer
                }
            } else {
                LoginView()
            }
        }
        .frame(width: 320)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerButton("Settings…") {
                NotificationCenter.default.post(name: .dibarOpenSettings, object: nil)
            }
            footerButton("History…") {
                NotificationCenter.default.post(name: .dibarOpenHistory, object: nil)
            }
            Spacer()
            footerButton("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 2)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 11))
            .cursor(.pointingHand)
    }
}

extension Notification.Name {
    static let dibarOpenSettings = Notification.Name("com.dibar.openSettings")
    static let dibarOpenHistory = Notification.Name("com.dibar.openHistory")
}
