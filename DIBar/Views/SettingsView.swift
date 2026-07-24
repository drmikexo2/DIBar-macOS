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
                    ToggleChip(title: "Site", isOn: Bindable(appState).menuBarShowSite)
                    ToggleChip(title: "Station", isOn: Bindable(appState).menuBarShowStation)
                    ToggleChip(title: "Artist", isOn: Bindable(appState).menuBarShowArtist)
                    ToggleChip(title: "Song", isOn: Bindable(appState).menuBarShowSong)
                }
            }

            if appState.menuBarPreviewLine1 != nil || appState.menuBarPreviewLine2 != nil {
                Image(nsImage: MenuBarLabelRenderer.labelImage(
                    line1: appState.menuBarPreviewLine1,
                    line2: appState.menuBarPreviewLine2,
                    playing: false
                ))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }

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
            .padding(.vertical, 8)

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
            .padding(.vertical, 8)
            .padding(.bottom, 2)
        }
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
        .frame(minHeight: 24)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

// MARK: - Toggle Chip

private struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(title)
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
