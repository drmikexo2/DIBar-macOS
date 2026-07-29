import SwiftUI

/// Custom dropdown (not a native Menu — NSMenu items can't right-justify
/// icons or color individual rows) styled to match the station list:
/// checkmark on the left for the selected network, accent text + blue
/// speaker on the right for the playing one.
struct NetworkPicker: View {
    @Environment(AppState.self) private var appState
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(appState.allNetworksSelected ? "All Sites" : appState.selectedNetwork.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch site")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DropdownContainer(width: 200) {
                DropdownRow(action: {
                    appState.selectAllNetworks()
                    isOpen = false
                }) {
                    DropdownCheckmark(isVisible: appState.allNetworksSelected)
                    Text("All Sites")
                        .font(.system(size: 12))
                    Spacer()
                }

                Divider()
                    .padding(.vertical, 4)

                ForEach(Network.allCases) { network in
                    NetworkRow(network: network) {
                        appState.selectNetwork(network)
                        isOpen = false
                    }
                }
            }
        }
    }
}

private struct NetworkRow: View {
    @Environment(AppState.self) private var appState
    let network: Network
    let action: () -> Void

    private var isPlaying: Bool {
        appState.playingNetwork == network && appState.audioPlayer.currentChannel != nil
    }

    var body: some View {
        DropdownRow(action: action) {
            DropdownCheckmark(isVisible: !appState.allNetworksSelected && network == appState.selectedNetwork)

            Text(network.displayName)
                .font(.system(size: 12))
                .fontWeight(isPlaying ? .semibold : .regular)
                .playingHighlight(isPlaying)

            Spacer()

            SpeakerIndicator(
                isCurrent: isPlaying,
                isAudible: appState.audioPlayer.isAudiblyPlaying
            )
        }
    }
}
