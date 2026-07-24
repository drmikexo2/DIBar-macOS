import SwiftUI

struct NetworkTabBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Network.allCases) { network in
                Button {
                    appState.selectNetwork(network)
                } label: {
                    Text(network.shortLabel)
                        .font(.system(size: 10, weight: network == appState.selectedNetwork ? .bold : .regular))
                        .foregroundStyle(network == appState.selectedNetwork ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            network == appState.selectedNetwork
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.quaternary.opacity(0.3))
    }
}
