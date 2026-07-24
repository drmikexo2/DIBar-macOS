import SwiftUI

struct NetworkPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            // Picker gives native menu-item selection state (checkmark), which
            // leaves each item's single image slot free for the speaker icon.
            Picker("", selection: Binding(
                get: { appState.selectedNetwork },
                set: { appState.selectNetwork($0) }
            )) {
                ForEach(Network.allCases) { network in
                    if appState.playingNetwork == network, appState.audioPlayer.currentChannel != nil {
                        Label(network.displayName, systemImage: "speaker.wave.2.fill").tag(network)
                    } else {
                        Text(network.displayName).tag(network)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(appState.selectedNetwork.displayName)
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch radio network")
    }
}
