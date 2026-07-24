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
        // Every row renders both glyph slots — invisible when inactive — so
        // the station names share one aligned column.
        let speaker = Text("\(Image(systemName: "speaker.wave.2.fill"))")
            .foregroundStyle(playing ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
        let check = Text("\(Image(systemName: "checkmark"))")
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
        return Text("\(speaker) \(check) \(network.displayName)")
    }
}
