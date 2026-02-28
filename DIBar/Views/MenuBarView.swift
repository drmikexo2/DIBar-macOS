import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                VStack(spacing: 0) {
                    PlayerControlsView()
                    Divider()
                    StationListView()
                    Divider()
                    SettingsView()
                }
            } else {
                LoginView()
            }
        }
        .frame(width: 320)
    }
}
