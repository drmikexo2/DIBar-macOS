import SwiftUI

struct NetworkPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            // Speaker lives in the item's single image slot (leading, keeps
            // names aligned); the selection checkmark is inline trailing text,
            // since the native checkmark gutter forms its own ragged column.
            ForEach(Network.allCases) { network in
                Button {
                    appState.selectNetwork(network)
                } label: {
                    if appState.playingNetwork == network, appState.audioPlayer.currentChannel != nil {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    if network == appState.selectedNetwork {
                        Text("\(network.displayName)  \(Image(systemName: "checkmark"))")
                    } else {
                        Text(network.displayName)
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
