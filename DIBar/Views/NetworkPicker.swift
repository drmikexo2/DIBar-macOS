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
                Text(appState.selectedNetwork.displayName)
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Network.allCases) { network in
                    NetworkRow(network: network) {
                        appState.selectNetwork(network)
                        isOpen = false
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: 200)
        }
    }
}

private struct NetworkRow: View {
    @Environment(AppState.self) private var appState
    let network: Network
    let action: () -> Void
    @State private var isHovered = false

    private var isSelected: Bool {
        network == appState.selectedNetwork
    }

    private var isPlaying: Bool {
        appState.playingNetwork == network && appState.audioPlayer.currentChannel != nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)

                Text(network.displayName)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)

                Spacer()

                Group {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
