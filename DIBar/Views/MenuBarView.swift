import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void

    var body: some View {
        Group {
            if appState.isLoggedIn {
                VStack(spacing: 0) {
                    if appState.audioPlayer.playbackError != nil, appState.playbackFailureLooksLikeNoPremium {
                        ErrorBanner(
                            message: "Playback failed — premium subscription may be required",
                            actionTitle: "Subscribe",
                            action: { openURL(AppState.subscriptionURL) },
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
            HoverTextButton(title: "Settings…") {
                onOpenSettings()
            }
            HoverTextButton(title: "History…") {
                onOpenHistory()
            }
            Spacer()
            HoverTextButton(title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 2)
    }
}

/// Text button that signals clickability: pointing-hand cursor and a
/// secondary→primary brightening on hover (tinted variants keep their color).
struct HoverTextButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(currentStyle)
            .onHover { isHovered = $0 }
            .cursor(.pointingHand)
    }

    private var currentStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint.opacity(isHovered ? 1.0 : 0.8))
        }
        return isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}
