import SwiftUI

struct NetworkPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            ForEach(Network.allCases) { network in
                Button {
                    appState.selectNetwork(network)
                } label: {
                    itemText(for: network)
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

    /// "(speaker) (checkmark) Name" — glyphs inline so both can appear at
    /// once (a menu item's image slot only fits a single image).
    private func itemText(for network: Network) -> Text {
        let playing = appState.playingNetwork == network && appState.audioPlayer.currentChannel != nil
        let selected = network == appState.selectedNetwork
        switch (playing, selected) {
        case (true, true):
            return Text("\(Image(systemName: "speaker.wave.2.fill")) \(Image(systemName: "checkmark")) \(network.displayName)")
        case (true, false):
            return Text("\(Image(systemName: "speaker.wave.2.fill")) \(network.displayName)")
        case (false, true):
            return Text("\(Image(systemName: "checkmark")) \(network.displayName)")
        case (false, false):
            return Text(network.displayName)
        }
    }
}
