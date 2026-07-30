import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(UpdatePresentationState.self) private var updatePresentation
    @Environment(\.openURL) private var openURL
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let phase = updatePresentation.phase {
                UpdateStatusBanner(phase: phase, action: onCheckForUpdates)
                Divider()
            }
            if appState.isLoggedIn {
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

private struct UpdateStatusBanner: View {
    let phase: UpdatePresentationState.Phase
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if case .recovering = phase {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }

    private var message: String {
        switch phase {
        case .available(let version):
            "DIBar \(version) is available"
        case .recovering(let version):
            "Finishing update to DIBar \(version)…"
        case .ready(let version):
            "DIBar \(version) is ready"
        case .failed:
            "Update couldn’t finish"
        }
    }

    private var actionTitle: String? {
        switch phase {
        case .available:
            "Update…"
        case .recovering:
            nil
        case .ready:
            "Restart"
        case .failed:
            "Retry…"
        }
    }

    private var iconName: String {
        switch phase {
        case .available:
            "arrow.down.circle.fill"
        case .recovering:
            "arrow.triangle.2.circlepath"
        case .ready:
            "arrow.clockwise.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if case .failed = phase { return .orange }
        return .accentColor
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
