import SwiftUI

struct NetworkPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            ForEach(Network.allCases) { network in
                Button {
                    appState.selectNetwork(network)
                } label: {
                    if network == appState.selectedNetwork {
                        Image(systemName: "checkmark")
                    }
                    Text(network.displayName)
                    if appState.playingNetwork == network, appState.audioPlayer.currentChannel != nil {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }
            }
        } label: {
            Text(appState.selectedNetwork.displayName)
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch radio network")
    }
}
