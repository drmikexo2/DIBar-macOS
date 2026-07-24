import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 2) {
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

            settingsRow("Show track in menu bar") {
                Toggle("", isOn: Bindable(appState).showTrackInMenuBar)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }

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
            .padding(.vertical, 2)

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
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
        .padding(.top, 6)
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
    }
}
