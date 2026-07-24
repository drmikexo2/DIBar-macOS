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
                    if appState.knowsSubscriptions && !appState.hasActiveSubscription(for: network) {
                        Image(systemName: "lock.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(appState.selectedNetwork.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch radio network")
    }
}
