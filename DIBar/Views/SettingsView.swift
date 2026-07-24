import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Quality")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Bindable(appState).selectedQuality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .onChange(of: appState.selectedQuality) { _, newValue in
                    Prefs.save(key: "quality", value: newValue.rawValue)
                    appState.restartStreamForQualityChange()
                }
            }
            .padding(.horizontal, 16)

            HStack {
                Text("Show track in menu bar")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Bindable(appState).showTrackInMenuBar)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)

            HStack {
                Text("Launch at login")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
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
            .padding(.horizontal, 16)

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
}
