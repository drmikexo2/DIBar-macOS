import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            settingsRow("Quality") {
                Picker("", selection: Bindable(appState).selectedQuality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: appState.selectedQuality) { _, newValue in
                    Prefs.save(key: "quality", value: newValue.rawValue)
                    appState.restartStreamForQualityChange()
                }
            }

            Divider()

            settingsRow("Menu bar") {
                HStack(spacing: 4) {
                    ToggleChip(title: "play/pause", systemImage: "playpause.fill", isOn: Bindable(appState).menuBarShowPlayState)
                    ToggleChip(title: "Site", isOn: Bindable(appState).menuBarShowSite)
                    ToggleChip(title: "Station", isOn: Bindable(appState).menuBarShowStation)
                    ToggleChip(title: "Artist", isOn: Bindable(appState).menuBarShowArtist)
                    ToggleChip(title: "Song", isOn: Bindable(appState).menuBarShowSong)
                }
            }

            Image(nsImage: MenuBarLabelRenderer.labelImage(
                line1: appState.menuBarPreviewLine1,
                line2: appState.menuBarPreviewLine2,
                glyph: previewGlyph
            ))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

            Divider()

            settingsRow("Launch at login") {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert the toggle if the system call failed
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            settingsRow("Save song history (on this Mac)") {
                Toggle("", isOn: Bindable(appState).saveListeningHistory)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("Remembers the songs and stations you listen to in a file on this Mac, so DIBar can show your listening stats. Nothing is sent anywhere.")

            if appState.saveListeningHistory, appState.historyRecorder.todayListenedSeconds >= 60 {
                settingsRow("Listened today") {
                    Text(Self.formatListeningTime(appState.historyRecorder.todayListenedSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Divider()

            Button {
                openURL(appState.subscriptionURL)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.membershipHeaderLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(appState.membershipDetailLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            HStack {
                Button("Logout") {
                    appState.logout()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .padding(.bottom, 2)
        }
        .padding(.vertical, 4)
    }

    /// Glyph for the preview card: honors the chip, shows the real state when
    /// a station is loaded, and demonstrates "playing" as the idle placeholder.
    private var previewGlyph: MenuBarLabelRenderer.PlaybackGlyph {
        guard appState.menuBarShowPlayState else { return .none }
        if appState.audioPlayer.currentChannel != nil {
            return MenuBarLabelRenderer.glyph(for: appState.audioPlayer)
        }
        return .playing
    }

    private static func formatListeningTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Caption on the left, control flush right, uniform height and padding.
    private func settingsRow(_ caption: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}

// MARK: - Toggle Chip

private struct ToggleChip: View {
    let title: String
    var systemImage: String? = nil
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: isOn ? .semibold : .regular))
                } else {
                    Text(title)
                        .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                }
            }
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.accentColor.opacity(isHovered ? 0.9 : 0), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .help(isOn ? "Hide \(title.lowercased()) in the menu bar" : "Show \(title.lowercased()) in the menu bar")
    }
}
