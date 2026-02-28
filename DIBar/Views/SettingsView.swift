import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

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
                    KeychainHelper.save(key: "quality", value: newValue.rawValue)
                    if let channel = appState.audioPlayer.currentChannel {
                        Task { await appState.loadChannels() }
                        appState.playChannel(channel)
                    }
                }
            }
            .padding(.horizontal, 16)

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
